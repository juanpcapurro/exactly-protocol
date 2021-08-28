import { expect } from "chai";
import { ethers } from "hardhat"
import { Contract, BigNumber } from "ethers"

Error.stackTraceLimit = Infinity;

describe("Exafin", function() {

    let exafin: Contract
    let underlyingToken: Contract

    let ownerAddress: string
    let userAddress: string
  
    beforeEach(async () => {
        const [owner, user] = await ethers.getSigners()
        ownerAddress = await owner.getAddress()
        userAddress = await user.getAddress()

        const totalSupply = ethers.utils.parseUnits("100000000000", 18);
        const SomeToken = await ethers.getContractFactory("SomeToken")
        underlyingToken = await SomeToken.deploy("Fake Stable", "FSTA", totalSupply.toString())
        await underlyingToken.deployed()

        const Exafin = await ethers.getContractFactory("Exafin");
        exafin = await Exafin.deploy(underlyingToken.address, "FSTA")
        await exafin.deployed();
    })

    it('it allows to give money to a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const underlyingAmount = 100
        await underlyingToken.approve(exafin.address, underlyingAmount)
        expect(await exafin.borrowFrom(ownerAddress, underlyingAmount, now))
            .to.emit(exafin, 'Borrowed')
            .withArgs(ownerAddress, underlyingAmount, now - (now % (86400 * 30)) + 86400 * 30)
        expect(await underlyingToken.balanceOf(exafin.address)).to.equal(underlyingAmount)
    })

    it('it allows to get money from a pool', async () => {
        const now = Math.floor(Date.now() / 1000)
        const borrowAmount = 100
        const lendAmount = 50

        // borrow from owneraddress wallet 
        await underlyingToken.approve(exafin.address, borrowAmount)
        await exafin.borrowFrom(ownerAddress, borrowAmount, now)

        // Lend to userAddress wallet
        expect(await exafin.lendTo(userAddress, lendAmount, now))
            .to.emit(exafin, 'Lent')
            .withArgs(userAddress, lendAmount, now - (now % (86400 * 30)) + 86400 * 30)
        expect(await underlyingToken.balanceOf(userAddress)).to.equal(lendAmount)
    })

});
