import { expect } from "chai";
import { ethers } from "hardhat";
import { ExaTime } from "./exactlyUtils";
import { Contract, BigNumber } from "ethers";
import { parseUnits } from "ethers/lib/utils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { DefaultEnv } from "./defaultEnv";

describe("ETHFixedLender - receive bare ETH instead of WETH", function () {
  let exactlyEnv: DefaultEnv;

  let weth: Contract;
  let eWeth: Contract;
  let ethFixedLender: Contract;
  let poolAccounting: Contract;

  let alice: SignerWithAddress;
  let owner: SignerWithAddress;
  const exaTime: ExaTime = new ExaTime();
  const nextPoolId: number = exaTime.nextPoolID();

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    [owner, alice] = await ethers.getSigners();

    exactlyEnv = await DefaultEnv.create({});

    weth = exactlyEnv.getUnderlying("WETH");
    eWeth = exactlyEnv.getEToken("WETH");
    ethFixedLender = exactlyEnv.getFixedLender("WETH");
    poolAccounting = exactlyEnv.getPoolAccounting("WETH");
    exactlyEnv.switchWallet(alice);
  });

  describe("depositToMaturityPoolEth vs depositToMaturityPool", () => {
    describe("WHEN depositing 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.depositMPETH("WETH", nextPoolId, "5");
        await tx;
      });
      it("THEN a DepositToMaturityPool event is emitted", async () => {
        await expect(tx)
          .to.emit(ethFixedLender, "DepositToMaturityPool")
          .withArgs(
            alice.address,
            parseUnits("5"),
            parseUnits("0"), // commission, its zero with the mocked rate
            nextPoolId
          );
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
          parseUnits("5")
        );
      });
      it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
        expect(
          await poolAccounting.mpUserSuppliedAmount(nextPoolId, alice.address)
        ).to.be.equal(parseUnits("5"));
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
      });
      describe("WHEN she deposits 5 WETH (ERC20) to a maturity pool", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.depositMP("WETH", nextPoolId, "5");
          await tx;
        });
        it("THEN a DepositToMaturityPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "DepositToMaturityPool")
            .withArgs(
              alice.address,
              parseUnits("5"),
              parseUnits("0"), // commission, its zero with the mocked rate
              nextPoolId
            );
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("5")
          );
        });
        it("AND the ETHFixedLender registers a supply of 5 WETH for the user", async () => {
          expect(
            await poolAccounting.mpUserSuppliedAmount(nextPoolId, alice.address)
          ).to.be.equal(parseUnits("5"));
        });
      });
    });
  });

  describe("depositToSmartPoolEth vs depositToSmartPool", () => {
    describe("WHEN alice deposits 5 ETH (bare ETH, not WETH) to a maturity pool", () => {
      let tx: any;
      beforeEach(async () => {
        tx = exactlyEnv.depositSPETH("WETH", "5");
        await tx;
      });
      it("THEN a DepositToSmartPool event is emitted", async () => {
        await expect(tx)
          .to.emit(ethFixedLender, "DepositToSmartPool")
          .withArgs(alice.address, parseUnits("5"));
      });
      it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
        expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
          parseUnits("5")
        );
      });
      it("AND alice has a balance of 5 eWETH", async () => {
        expect(await eWeth.balanceOf(alice.address)).to.be.equal(
          parseUnits("5")
        );
      });
    });

    describe("GIVEN alice has some WETH", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
      });
      describe("WHEN she deposits 5 WETH (ERC20) to the smart pool", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.depositSP("WETH", "5");
          await tx;
        });
        it("THEN a DepositToSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "DepositToSmartPool")
            .withArgs(alice.address, parseUnits("5"));
        });
        it("AND the ETHFixedLender contract has a balance of 5 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("5")
          );
        });
        it("AND alice has a balance of 5 eWETH", async () => {
          expect(await eWeth.balanceOf(alice.address)).to.be.equal(
            parseUnits("5")
          );
        });
      });
    });
  });

  describe("withdrawFromSmartPoolEth vs withdrawFromSmartPool", () => {
    describe("GIVEN alice already has a 5 ETH SP deposit", () => {
      beforeEach(async () => {
        weth.transfer(alice.address, parseUnits("10"));
        await exactlyEnv.depositSP("WETH", "5");
      });
      describe("WHEN withdrawing to 3 eWETH to ETH", () => {
        let tx: any;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await ethers.provider.getBalance(
            alice.address
          );
          tx = exactlyEnv.withdrawSPETH("WETH", "3");
          await tx;
        });
        it("THEN a WithdrawFromSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromSmartPool")
            .withArgs(alice.address, parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("2")
          );
        });
        it("AND alice's ETH balance has increased by roughly 3", async () => {
          const newBalance = await ethers.provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("2.95"));
          expect(balanceDiff).to.be.lt(parseUnits("3"));
        });
      });
      describe("WHEN withdrawing 3 eWETH to WETH", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.withdrawSP("WETH", "3");
          await tx;
        });
        it("THEN a WithdrawFromSmartPool event is emitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromSmartPool")
            .withArgs(alice.address, parseUnits("3"));
        });
        it("AND the ETHFixedLender contract has a balance of 2 WETH", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("2")
          );
        });
        it("AND alice recovers her 2 ETH", async () => {
          expect(await weth.balanceOf(alice.address)).to.equal(parseUnits("8"));
        });
      });
    });
  });

  describe("withdrawFromMaturityPoolETH vs withdrawFromMaturityPool", () => {
    describe("GIVEN alice has a deposit to ETH maturity AND maturity is reached", () => {
      beforeEach(async () => {
        exactlyEnv.switchWallet(owner);
        weth.transfer(alice.address, parseUnits("10"));
        exactlyEnv.switchWallet(alice);
        await exactlyEnv.depositMP("WETH", nextPoolId, "10");
        await exactlyEnv.moveInTime(nextPoolId);
      });
      describe("WHEN she withdraws to ETH", () => {
        let tx: any;
        let aliceETHBalanceBefore: BigNumber;
        beforeEach(async () => {
          aliceETHBalanceBefore = await ethers.provider.getBalance(
            alice.address
          );
          tx = exactlyEnv.withdrawMPETH("WETH", nextPoolId, "10");
          await tx;
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromMaturityPool")
            .withArgs(alice.address, parseUnits("10"), nextPoolId);
        });
        it("AND alices ETH balance increases accordingly", async () => {
          const newBalance = await ethers.provider.getBalance(alice.address);
          const balanceDiff = newBalance.sub(aliceETHBalanceBefore);
          expect(balanceDiff).to.be.gt(parseUnits("9.95"));
          expect(balanceDiff).to.be.lt(parseUnits("10"));
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("0")
          );
        });
      });
      describe("WHEN she withdraws to WETH", () => {
        let tx: any;
        beforeEach(async () => {
          tx = exactlyEnv.withdrawMP("WETH", nextPoolId, "10");
          await tx;
        });
        it("THEN a WithdrawFromMaturityPool event is emmitted", async () => {
          await expect(tx)
            .to.emit(ethFixedLender, "WithdrawFromMaturityPool")
            .withArgs(alice.address, parseUnits("10"), nextPoolId);
        });
        it("AND alices WETH balance increases accordingly", async () => {
          expect(await weth.balanceOf(alice.address)).to.equal(
            parseUnits("10")
          );
        });
        it("AND the ETHFixedLender contracts WETH balance decreased accordingly", async () => {
          expect(await weth.balanceOf(ethFixedLender.address)).to.equal(
            parseUnits("0")
          );
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
