import { ethers } from 'hardhat';
import { MakerLabels, MakerDemoValues } from './config'
import { id } from 'ethers/lib/utils'
import { Contract, BigNumber } from "ethers"
import { DSSMath } from './dssmath'

export class MakerEnv {
  vat: Contract
  weth: Contract
  wethJoin: Contract

  constructor(
    vat: Contract,
    weth: Contract,
    wethJoin: Contract
  ) {
    this.vat = vat
    this.weth = weth
    this.wethJoin = wethJoin
  }

  public static async setup() {
    const Vat = await ethers.getContractFactory("Vat");
    const GemJoin = await ethers.getContractFactory("GemJoin");
    const Weth = await ethers.getContractFactory("WETH10");

    // Set up vat, join and weth
    const weth = await Weth.deploy()
    await weth.deployed();

    const vat = await Vat.deploy()
    await vat.deployed();

    await vat.init(MakerLabels.WETH)
    const wethJoin = await GemJoin.deploy(vat.address, MakerLabels.WETH, weth.address)
    await wethJoin.deployed();

    // Setup vat
    await vat.functions['file(bytes32,bytes32,uint256)'](MakerLabels.WETH, MakerLabels.spotLabel, MakerDemoValues.spot)
    await vat.functions['file(bytes32,bytes32,uint256)'](MakerLabels.WETH, MakerLabels.upperBoundLineLabelForCollateral, MakerDemoValues.limits)
    await vat.functions['file(bytes32,uint256)'](MakerLabels.upperBoundLineLabelForAll, MakerDemoValues.limits)
    await vat.fold(MakerLabels.WETH, vat.address, DSSMath.subBN(MakerDemoValues.rate1, DSSMath.toRay(1))) // Fold only the increase from 1.0
    // ^^ https://docs.makerdao.com/smart-contract-modules/rates-module#stability-fee-accumulation

    // Permissions
    await vat.rely(vat.address)
    await vat.rely(wethJoin.address)

    return new MakerEnv(vat, weth, wethJoin)
  }

}

export class ExactlyEnv {
  maker: MakerEnv
  treasury: Contract
  pawnbroker: Contract

  constructor(maker: MakerEnv, treasury: Contract, pawnbroker: Contract) {
    this.maker = maker
    this.treasury = treasury
    this.pawnbroker = pawnbroker
  }

  public static async setupTreasury(maker: MakerEnv) {
    const Treasury = await ethers.getContractFactory("Treasury")
    const treasury = await Treasury.deploy(
      maker.vat.address,
      maker.weth.address,
      maker.wethJoin.address
    )

    await treasury.deployed()

    return treasury
  }

  public static async setupPawnbroker(treasury: Contract) {
    const Pawnbroker = await ethers.getContractFactory("Pawnbroker");

    const pawnbroker = await Pawnbroker.deploy(treasury.address)
    await pawnbroker.deployed();

    const treasuryFunctions = ['pushWeth', 'pullWeth'].map((func) =>
      id(func + '(address,uint256)').slice(0,10) // "0x" + bytes4 => 10 chars
    )
    await treasury.batchOrchestrate(pawnbroker.address, treasuryFunctions)

    return pawnbroker
  }

  public static async setup() {
    const maker = await MakerEnv.setup()
    const treasury = await this.setupTreasury(maker)
    const pawnbroker = await this.setupPawnbroker(treasury)
    return new ExactlyEnv(maker, treasury, pawnbroker)
  }

  // Convert eth to weth and post it to fyDai
  public async postWeth(user: string, _wethTokens: BigNumber) {
    await this.maker.weth.deposit({ from: user, value: _wethTokens.toString() })
    await this.maker.weth.approve(this.treasury.address, _wethTokens, { from: user })
    await this.pawnbroker.post(MakerLabels.WETH, user, user, _wethTokens, { from: user })
  }

}
