import { expect } from "chai";
import { ethers } from "hardhat";
import { parseUnits, formatUnits } from "@ethersproject/units";
import { Contract } from "ethers";
import {
  ProtocolError,
  ExactlyEnv,
  ExaTime,
  errorGeneric,
  DefaultEnv,
} from "./exactlyUtils";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Liquidity computations", function () {
  let auditor: Contract;
  let exactlyEnv: DefaultEnv;
  let nextPoolID = new ExaTime().nextPoolID();

  let bob: SignerWithAddress;
  let laura: SignerWithAddress;

  let fixedLenderDAI: Contract;
  let dai: Contract;
  let fixedLenderUSDC: Contract;
  let usdc: Contract;
  let fixedLenderWBTC: Contract;
  let wbtc: Contract;

  let mockedTokens = new Map([
    [
      "DAI",
      {
        decimals: 18,
        collateralRate: parseUnits("0.8", 18),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "USDC",
      {
        decimals: 6,
        collateralRate: parseUnits("0.8", 18),
        usdPrice: parseUnits("1"),
      },
    ],
    [
      "WBTC",
      {
        decimals: 8,
        collateralRate: parseUnits("0.6", 18),
        usdPrice: parseUnits("60000"),
      },
    ],
  ]);

  let snapshot: any;
  beforeEach(async () => {
    snapshot = await ethers.provider.send("evm_snapshot", []);
  });

  beforeEach(async () => {
    // the owner deploys the contracts
    // bob the borrower
    // laura the lender
    [bob, laura] = await ethers.getSigners();

    exactlyEnv = await ExactlyEnv.create({ mockedTokens });
    auditor = exactlyEnv.auditor;

    fixedLenderDAI = exactlyEnv.getFixedLender("DAI");
    dai = exactlyEnv.getUnderlying("DAI");
    fixedLenderUSDC = exactlyEnv.getFixedLender("USDC");
    usdc = exactlyEnv.getUnderlying("USDC");
    fixedLenderWBTC = exactlyEnv.getFixedLender("WBTC");
    wbtc = exactlyEnv.getUnderlying("WBTC");

    // TODO: perhaps pass the addresses to ExactlyEnv.create and do all the
    // transfers in the same place?
    // wbtc laura will provide liquidity on
    await wbtc.transfer(laura.address, parseUnits("100000", 8));
    await dai.transfer(laura.address, parseUnits("100000"));
    // dai & usdc bob will use as collateral
    await dai.transfer(bob.address, parseUnits("100000"));
    await usdc.transfer(bob.address, parseUnits("100000", 6));
    // we make DAI & USDC count as collateral
    await auditor.enterMarkets(
      [fixedLenderDAI.address, fixedLenderUSDC.address],
      nextPoolID
    );
    await auditor
      .connect(laura)
      .enterMarkets(
        [fixedLenderDAI.address, fixedLenderUSDC.address],
        nextPoolID
      );
  });

  describe("positions arent immediately liquidateable", () => {
    describe("GIVEN laura deposits 1kdai to a maturity pool", () => {
      beforeEach(async () => {
        const amount = parseUnits("1000");
        await dai.connect(laura).approve(fixedLenderDAI.address, amount);
        await fixedLenderDAI
          .connect(laura)
          .depositToMaturityPool(amount, nextPoolID);
      });

      it("THEN lauras liquidity is collateralRate*collateral -  0.8*1000 == 800, AND she has no shortfall", async () => {
        const [liquidity, shortfall] = await auditor.getAccountLiquidity(
          laura.address,
          nextPoolID
        );

        const expectedLiquidity = 800;

        expect(parseFloat(formatUnits(liquidity))).to.be.eq(expectedLiquidity);
        expect(shortfall).to.be.eq(parseUnits("0"));
      });
      // TODO: a test where the supply interest is != 0, see if there's an error like the one described in this commit
      it("AND she has zero debt and is owed 1000DAI", async () => {
        const [supplied, owed] = await fixedLenderDAI.getAccountSnapshot(
          laura.address,
          nextPoolID
        );
        expect(supplied).to.be.eq(parseUnits("1000"));
        expect(owed).to.be.eq(parseUnits("0"));
      });
      describe("AND GIVEN a 1% borrow interest rate", () => {
        beforeEach(async () => {
          await exactlyEnv
            .getInterestRateModel()
            .setBorrowRate(parseUnits("0.01"));
        });
        it("AND WHEN laura asks for a 800 DAI loan, THEN it reverts because the interests make the owed amount larger than liquidity", async () => {
          await expect(
            fixedLenderDAI
              .connect(laura)
              .borrowFromMaturityPool(parseUnits("800"), nextPoolID)
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
      });

      describe("AND WHEN laura asks for a 800 DAI loan", () => {
        beforeEach(async () => {
          await fixedLenderDAI
            .connect(laura)
            .borrowFromMaturityPool(parseUnits("800"), nextPoolID);
        });
        it("THEN lauras liquidity is zero, AND she has no shortfall", async () => {
          const [liquidity, shortfall] = await auditor.getAccountLiquidity(
            laura.address,
            nextPoolID
          );
          expect(liquidity).to.eq(parseUnits("0"));
          expect(shortfall).to.eq(parseUnits("0"));
        });
        it("AND she has 799+interest debt and is owed 1000DAI", async () => {
          const [supplied, borrowed] = await fixedLenderDAI.getAccountSnapshot(
            laura.address,
            nextPoolID
          );

          expect(supplied).to.be.eq(parseUnits("1000"));
          expect(borrowed).to.eq(parseUnits("800"));
        });
      });
    });
  });

  describe("support for tokens with different decimals", () => {
    describe("GIVEN theres liquidity on the btc fixedLender", () => {
      beforeEach(async () => {
        // laura supplies wbtc to the protocol to have lendable money in the pool
        const amount = parseUnits("3", 8);
        await wbtc.connect(laura).approve(fixedLenderWBTC.address, amount);
        await fixedLenderWBTC
          .connect(laura)
          .depositToMaturityPool(amount, nextPoolID);
      });

      describe("AND GIVEN Bob provides 60kdai (18 decimals) as collateral", () => {
        beforeEach(async () => {
          await dai
            .connect(bob)
            .approve(fixedLenderDAI.address, parseUnits("60000"));
          await fixedLenderDAI
            .connect(bob)
            .depositToMaturityPool(parseUnits("60000"), nextPoolID);
        });
        // Here I'm trying to make sure we use the borrowed token's decimals
        // properly to compute liquidity
        // if we asume (wrongly) that all tokens have 18 decimals, then computing
        // the simulated liquidity for a token  with less than 18 decimals will
        // enable the creation of an undercolalteralized loan, since the
        // simulated liquidity would be orders of magnitude lower than the real
        // one
        it("WHEN he tries to take a 1btc (8 decimals) loan (100% collateralization), THEN it reverts", async () => {
          // We expect liquidity to be equal to zero
          await expect(
            fixedLenderWBTC
              .connect(bob)
              .borrowFromMaturityPool(parseUnits("1", 8), nextPoolID)
          ).to.be.revertedWith(
            errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
          );
        });
      });

      describe("AND GIVEN Bob provides 20kdai (18 decimals) and 40kusdc (6 decimals) as collateral", () => {
        beforeEach(async () => {
          await dai
            .connect(bob)
            .approve(fixedLenderDAI.address, parseUnits("20000"));
          await fixedLenderDAI
            .connect(bob)
            .depositToMaturityPool(parseUnits("20000"), nextPoolID);
          await usdc
            .connect(bob)
            .approve(fixedLenderUSDC.address, parseUnits("40000", 6));
          await fixedLenderUSDC
            .connect(bob)
            .depositToMaturityPool(parseUnits("40000", 6), nextPoolID);
        });
        describe("AND GIVEN Bob takes a 0.5wbtc loan (200% collateralization)", () => {
          beforeEach(async () => {
            await fixedLenderWBTC
              .connect(bob)
              .borrowFromMaturityPool(parseUnits("0.5", 8), nextPoolID);
          });
          describe("AND GIVEN the pool matures", () => {
            beforeEach(async () => {
              // Move in time to maturity
              await ethers.provider.send("evm_setNextBlockTimestamp", [
                nextPoolID,
              ]);
              await ethers.provider.send("evm_mine", []);
            });
            // this is similar to the previous test case, but instead of
            // computing the simulated liquidity with a supplyAmount of zero and
            // the to-be-loaned amount as the borrowAmount, the amount of
            // collateral to withdraw is passed as the supplyAmount
            it("WHEN he tries to withdraw the usdc (8 decimals) collateral, THEN it reverts ()", async () => {
              // We expect liquidity to be equal to zero
              await expect(
                fixedLenderUSDC
                  .connect(bob)
                  .withdrawFromMaturityPool(
                    bob.address,
                    parseUnits("40000", 6),
                    nextPoolID
                  )
              ).to.be.revertedWith(
                errorGeneric(ProtocolError.INSUFFICIENT_LIQUIDITY)
              );
            });
          });
        });
      });
    });
  });

  afterEach(async () => {
    await ethers.provider.send("evm_revert", [snapshot]);
    await ethers.provider.send("evm_mine", []);
  });
});
