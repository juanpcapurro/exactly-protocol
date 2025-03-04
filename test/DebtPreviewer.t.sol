// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import { ForkTest, stdError } from "./Fork.t.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Pool, Limit, Rates, Leverage, DebtPreviewer, InvalidPreview } from "../contracts/periphery/DebtPreviewer.sol";
import { FixedLib } from "../contracts/utils/FixedLib.sol";
import {
  Market,
  ERC20,
  IPermit2,
  IPriceFeed,
  DebtManager,
  IBalancerVault
} from "../contracts/periphery/DebtManager.sol";
import { Auditor, InsufficientAccountLiquidity } from "../contracts/Auditor.sol";

contract DebtPreviewerTest is ForkTest {
  using FixedPointMathLib for uint256;

  address internal constant ALICE = address(0x420);
  uint160 internal constant MIN_SQRT_RATIO = 4295128739;
  uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
  DebtPreviewer internal debtPreviewer;
  DebtManager internal debtManager;
  Market internal marketOP;
  Market internal marketWETH;
  Market internal marketUSDC;
  Market internal marketwstETH;
  ERC20 internal weth;
  ERC20 internal usdc;
  ERC20 internal wstETH;
  Auditor internal auditor;
  uint256 internal maturity;

  function setUp() external {
    vm.createSelectFork(vm.envString("OPTIMISM_NODE"), 99_811_375);
    auditor = Auditor(deployment("Auditor"));
    IPermit2 permit2 = IPermit2(deployment("Permit2"));
    marketOP = Market(deployment("MarketOP"));
    marketWETH = Market(deployment("MarketWETH"));
    marketUSDC = Market(deployment("MarketUSDC"));
    marketwstETH = Market(deployment("MarketwstETH"));
    weth = ERC20(deployment("WETH"));
    usdc = ERC20(deployment("USDC"));
    wstETH = ERC20(deployment("wstETH"));
    debtManager = DebtManager(
      address(
        new ERC1967Proxy(
          address(new DebtManager(auditor, permit2, IBalancerVault(deployment("BalancerVault")))),
          abi.encodeCall(DebtManager.initialize, ())
        )
      )
    );

    Pool[] memory pools = new Pool[](2);
    pools[0] = Pool(address(weth), address(usdc));
    pools[1] = Pool(address(weth), address(wstETH));
    uint24[] memory fees = new uint24[](2);
    fees[0] = 500;
    fees[1] = 500;

    debtPreviewer = new DebtPreviewer(debtManager);

    deal(address(usdc), address(this), 22_000_000e6);
    deal(address(weth), address(this), 1_000e18);
    deal(address(wstETH), address(this), 1_000e18);
    marketUSDC.approve(address(debtManager), type(uint256).max);
    marketWETH.approve(address(debtManager), type(uint256).max);
    marketwstETH.approve(address(debtManager), type(uint256).max);
    weth.approve(address(marketWETH), type(uint256).max);
    usdc.approve(address(marketUSDC), type(uint256).max);
    usdc.approve(address(debtManager), type(uint256).max);
    wstETH.approve(address(debtManager), type(uint256).max);
    wstETH.approve(address(marketwstETH), type(uint256).max);
    weth.approve(address(debtManager), type(uint256).max);
    auditor.enterMarket(marketUSDC);
    maturity = block.timestamp - (block.timestamp % FixedLib.INTERVAL) + FixedLib.INTERVAL;
  }

  function testPreviewLeverage() external {
    uint256 ratio = 2e18;
    uint256 principal = 10_000e6;
    debtManager.leverage(marketUSDC, principal, ratio);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    (uint256 collateralAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    assertApproxEqAbs(uint256(leverage.principal), principal, 2e18);
    assertApproxEqAbs(leverage.deposit, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leverage.ratio, ratio, 0.0003e18);
    assertApproxEqAbs(
      leverage.maxRatio,
      uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)),
      0.000000004e18
    );
  }

  function testPreviewEmptyLeverage() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    (uint256 collateralAdjustFactor, , , , ) = auditor.markets(marketUSDC);
    (uint256 debtAdjustFactor, , , , ) = auditor.markets(marketUSDC);

    assertEq(leverage.principal, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.borrow, 0);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - collateralAdjustFactor.mulWadDown(debtAdjustFactor)));
  }

  function testPreviewLeverageSameAsset() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    (uint256 adjustFactor, , , , ) = auditor.markets(marketUSDC);
    uint256 principal = 1_000e6;
    uint256 ratio = leverage.maxRatio - 0.0001e18;

    debtManager.leverage(marketUSDC, principal, ratio);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
    assertEq(leverage.principal, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.borrow, 0);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.maxRatio, uint256(1e18).divWadDown(1e18 - adjustFactor.mulWadDown(adjustFactor)));

    leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    assertApproxEqAbs(uint256(leverage.principal), 1_000e6, 3);
    assertApproxEqAbs(leverage.deposit, principal.mulWadDown(ratio), 1);
    assertApproxEqAbs(leverage.borrow, principal.mulWadDown(ratio - 1e18), 1);
    assertApproxEqAbs(leverage.ratio, ratio, 3e10);
    assertApproxEqAbs(leverage.maxRatio, ratio, 1e14);
  }

  function testPreviewLeverageSameAssetNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1e18);
    assertEq(leverage.ratio, 0);
    assertEq(leverage.deposit, 0);
    assertEq(leverage.maxWithdraw, 0);
    assertApproxEqAbs(leverage.borrow, 1 ether, 1);
    assertEq(leverage.maxRatio, 3396739130434782608);
    assertEq(leverage.principal, -1e18);

    Limit memory limit = debtPreviewer.previewLeverage(marketWETH, marketWETH, address(this), 1e18, 2e18, 1e18);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertEq(limit.principal, 0);
    assertEq(limit.borrow, marketWETH.previewRefund(floatingBorrowShares));
    assertEq(limit.maxRatio, 3396739130434782608);
    assertEq(limit.deposit, 1e18);

    limit = debtPreviewer.previewLeverage(marketWETH, marketWETH, address(this), 2e18, 3e18, 1e18);
    assertEq(limit.principal, 1e18);
    assertEq(limit.maxRatio, 3396739130434782608);
    assertEq(limit.deposit, 3e18);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares) * 2, 2);

    debtManager.leverage(marketWETH, 2e18, 3e18);
    (, , floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.deposit, marketWETH.maxWithdraw(address(this)), 4);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 1);
  }

  function testPreviewLeverageSameAssetPartialNegativePrincipal() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketWETH.borrow(1e18, address(this), address(this));
    marketWETH.deposit(0.5e18, address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1.01e18);
    Limit memory limit = debtPreviewer.previewLeverage(
      marketWETH,
      marketWETH,
      address(this),
      leverage.minDeposit,
      4e18,
      1e18
    );
    debtManager.leverage(marketWETH, leverage.minDeposit, limit.ratio);
    (, , uint256 floatingBorrowShares) = marketWETH.accounts(address(this));
    assertApproxEqAbs(limit.deposit, marketWETH.maxWithdraw(address(this)), 4);
    assertApproxEqAbs(limit.borrow, marketWETH.previewRefund(floatingBorrowShares), 2);
  }

  function testPreviewLeverageBalancerAvailableLiquidity() external {
    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    Market[] memory markets = auditor.allMarkets();
    assertEq(leverage.availableAssets.length, markets.length);
    assertEq(address(leverage.availableAssets[1].asset), address(usdc));
    assertEq(leverage.availableAssets[1].liquidity, usdc.balanceOf(address(debtManager.balancerVault())));
  }

  function testPreviewSameAssetInvalidLeverageShouldCapRatio() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketUSDC.borrow(5_000e6, address(this), address(this));

    Limit memory limit = debtPreviewer.previewLeverage(marketUSDC, marketUSDC, address(this), 6_000e6, 5e18, 1e18);
    assertEq(limit.ratio, 6000000006000000007);
  }

  function testPreviewLeverageSameUSDCAssetWithDeposit() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(2.3e18, address(this), address(this));

    uint256 newDeposit = 5_000e6;
    Limit memory limit = debtPreviewer.previewLeverage(marketUSDC, marketUSDC, address(this), newDeposit, 1e18, 1e18);
    debtManager.leverage(marketUSDC, newDeposit, limit.maxRatio - 0.003e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewMaxRatioWithdrawWithSameAssetLeverage() external {
    debtManager.leverage(marketUSDC, 100_000e6, 4e18);
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 10_000e6, 1e18, 1e18).maxRatio,
      5.81e18,
      0.008e18
    );
    assertApproxEqAbs(
      debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 40_000e6, 1e18, 1e18).maxRatio,
      5.81e18,
      0.008e18
    );
  }

  function testPreviewLeverageSameUSDCAssetMaxRatioMultipleCollateralAndDebt() external {
    marketUSDC.deposit(10_000e6, address(this));
    auditor.enterMarket(marketUSDC);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketWETH.borrow(0.5e18, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    debtManager.leverage(marketUSDC, 0, leverage.maxRatio - 0.005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageSameWETHAssetMaxRatioMultipleCollateralAndDebt() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(2_000e6, address(this), address(this));

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), 1e18);
    debtManager.leverage(marketWETH, 0, leverage.maxRatio - 0.0005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 0.0003e18);
  }

  function testPreviewLeverageSameWETHAssetMultipleCollateralAndDebtWithMinHealthFactor() external {
    marketWETH.deposit(5e18, address(this));
    auditor.enterMarket(marketWETH);
    marketOP.borrow(1_000e18, address(this), address(this));
    marketUSDC.borrow(2_000e6, address(this), address(this));
    uint256 minHealthFactor = 1.05e18;

    Leverage memory leverage = debtPreviewer.leverage(marketWETH, marketWETH, address(this), minHealthFactor);
    debtManager.leverage(marketWETH, 0, leverage.maxRatio - 0.0005e18);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), minHealthFactor, 0.0003e18);
  }

  function testPreviewDeleverageSameAsset() external {
    debtManager.leverage(marketUSDC, 100_000e6, 3e18);

    Limit memory limit = debtPreviewer.previewDeleverage(marketUSDC, marketUSDC, address(this), 10_000e6, 2e18, 1e18);

    debtManager.deleverage(marketUSDC, 10_000e6, 2e18);
    assertApproxEqAbs(marketUSDC.maxWithdraw(address(this)), limit.deposit, 2);
    assertApproxEqAbs(floatingBorrowAssets(marketUSDC, address(this)), limit.borrow, 1);

    Leverage memory leverage = debtPreviewer.leverage(marketUSDC, marketUSDC, address(this), 1e18);
    assertApproxEqAbs(leverage.maxRatio, limit.maxRatio, 6e8);

    vm.expectRevert(abi.encodeWithSelector(InsufficientAccountLiquidity.selector));
    debtManager.leverage(marketUSDC, 0, limit.maxRatio + 0.001e18);

    debtManager.leverage(marketUSDC, 0, limit.maxRatio);
    (uint256 coll, uint256 debt) = auditor.accountLiquidity(address(this), Market(address(0)), 0);
    assertApproxEqAbs(coll.divWadDown(debt), 1e18, 5e7);
  }

  function testLeverageRatesCrossAsset() external {
    uint256 depositRate = 1.91e16;
    Rates memory rates = debtPreviewer.leverageRates(
      marketUSDC,
      marketWETH,
      address(this),
      10_000e6,
      3e18,
      depositRate,
      0,
      0
    );

    assertEq(rates.deposit, depositRate.mulWadDown(3e18));
    assertEq(rates.borrow, 71562762755180610);
    assertEq(rates.native, 0);
    assertEq(rates.rewards.length, 2);
    assertEq(address(rates.rewards[1].asset), 0x4200000000000000000000000000000000000042);
    assertEq(address(rates.rewards[0].asset), 0x4200000000000000000000000000000000000042);
    assertEq(rates.rewards[0].assetSymbol, "OP");
    assertEq(rates.rewards[1].assetSymbol, "OP");
    assertEq(rates.rewards[0].assetName, "Optimism");
    assertEq(rates.rewards[1].assetName, "Optimism");
    assertEq(rates.rewards[0].deposit, 72979811102062440);
    assertEq(rates.rewards[0].borrow, 0);
    assertEq(rates.rewards[1].deposit, 0);
    assertEq(rates.rewards[1].borrow, 37023661655907600);
  }

  function testLeverageRatesSameAsset() external {
    uint256 depositRate = 1.91e16;
    Rates memory rates = debtPreviewer.leverageRates(
      marketUSDC,
      marketUSDC,
      address(this),
      10_000e6,
      2.5e18,
      depositRate,
      0,
      0
    );

    assertEq(rates.deposit, depositRate.mulWadDown(2.5e18));
    assertEq(rates.borrow, 50832100630765815);
    assertEq(rates.native, 0);
    assertEq(rates.rewards.length, 1);
    assertEq(address(rates.rewards[0].asset), 0x4200000000000000000000000000000000000042);
    assertEq(rates.rewards[0].assetSymbol, "OP");
    assertEq(rates.rewards[0].assetName, "Optimism");
    assertEq(rates.rewards[0].borrow, 26229302711998560);
    assertEq(rates.rewards[0].deposit, 60816509251718700);
  }

  function testDeleverageRatesSameAsset() external {
    debtManager.leverage(marketUSDC, 10_000e6, 3e18);
    uint256 depositRate = 1.91e16;
    Rates memory rates = debtPreviewer.leverageRates(marketUSDC, marketUSDC, address(this), 0, 2e18, depositRate, 0, 0);

    assertEq(rates.deposit, depositRate.mulWadDown(2e18));
    assertEq(rates.borrow, 33873354732054336);
    assertEq(rates.native, 0);

    assertEq(rates.rewards.length, 1);
    assertEq(address(rates.rewards[0].asset), 0x4200000000000000000000000000000000000042);
    assertEq(rates.rewards[0].assetSymbol, "OP");
    assertEq(rates.rewards[0].assetName, "Optimism");
    assertEq(rates.rewards[0].borrow, 17475604202887560);
    assertEq(rates.rewards[0].deposit, 48615737527381200);
  }

  function testLeverageRatesZeroPrincipalCrossAsset() external {
    uint256 depositRate = 1.91e16;
    Rates memory rates = debtPreviewer.leverageRates(marketUSDC, marketWETH, address(this), 0, 2e18, depositRate, 0, 0);

    assertEq(rates.deposit, depositRate.mulWadDown(2e18));
    assertEq(rates.borrow, 35699727952228352);
    assertEq(rates.native, 0);

    assertEq(rates.rewards.length, 2);
    assertEq(address(rates.rewards[0].asset), 0x4200000000000000000000000000000000000042);
    assertEq(address(rates.rewards[1].asset), 0x4200000000000000000000000000000000000042);
    assertEq(rates.rewards[0].assetSymbol, "OP");
    assertEq(rates.rewards[1].assetSymbol, "OP");
    assertEq(rates.rewards[0].assetName, "Optimism");
    assertEq(rates.rewards[1].assetName, "Optimism");
    assertEq(rates.rewards[0].deposit, 48653207401374960);
    assertEq(rates.rewards[0].borrow, 0);
    assertEq(rates.rewards[1].deposit, 0);
    assertEq(rates.rewards[1].borrow, 18511830827953800);
  }

  function testLeverageRatesZeroPrincipalSameAsset() external {
    uint256 depositRate = 1.91e16;
    Rates memory rates = debtPreviewer.leverageRates(marketUSDC, marketUSDC, address(this), 0, 2e18, depositRate, 0, 0);

    assertEq(rates.deposit, depositRate.mulWadDown(2e18));
    assertEq(rates.borrow, 33875696070336447);
    assertEq(rates.native, 0);

    assertEq(rates.rewards.length, 1);
    assertEq(address(rates.rewards[0].asset), 0x4200000000000000000000000000000000000042);
    assertEq(rates.rewards[0].assetSymbol, "OP");
    assertEq(rates.rewards[0].assetName, "Optimism");
    assertEq(rates.rewards[0].deposit, 48653207401374960);
    assertEq(rates.rewards[0].borrow, 17486201807999040);
  }

  function testLeverageRatesWithNativeBorrow() external {
    uint256 nativeRateBorrow = 3.9e18;
    uint256 depositRate = 1.9e18;
    uint256 nativeRate = 3.9e18;
    uint256 ratio = 3e18;
    Rates memory rates = debtPreviewer.leverageRates(
      marketWETH,
      marketWETH,
      address(this),
      0,
      ratio,
      depositRate,
      nativeRate,
      nativeRateBorrow
    );

    assertEq(rates.deposit, depositRate.mulWadDown(ratio), "deposit");
    assertEq(rates.native, int256(nativeRate.mulWadDown(ratio) - nativeRateBorrow.mulWadDown(ratio - 1e18)), "native");
  }

  function testLeverageRatesWithNegativeNativeResult() external {
    uint256 nativeRateBorrow = 3.9e18;
    uint256 depositRate = 1.9e18;
    uint256 nativeRate = 0;
    uint256 ratio = 3e18;
    Rates memory rates = debtPreviewer.leverageRates(
      marketWETH,
      marketWETH,
      address(this),
      0,
      ratio,
      depositRate,
      nativeRate,
      nativeRateBorrow
    );

    assertEq(rates.deposit, depositRate.mulWadDown(ratio), "deposit");
    assertEq(
      rates.native,
      int256(nativeRate.mulWadDown(ratio)) - int256(nativeRateBorrow.mulWadDown(ratio - 1e18)),
      "native"
    );
  }

  function crossPrincipal(Market marketDeposit, Market marketBorrow, address account) internal view returns (int256) {
    (, , , , IPriceFeed priceFeedIn) = debtManager.auditor().markets(marketDeposit);
    (, , , , IPriceFeed priceFeedOut) = debtManager.auditor().markets(marketBorrow);

    uint256 collateral = marketDeposit.maxWithdraw(account);
    uint256 debt = floatingBorrowAssets(marketBorrow, account)
      .mulDivDown(debtManager.auditor().assetPrice(priceFeedOut), 10 ** marketBorrow.decimals())
      .mulDivDown(10 ** marketDeposit.decimals(), debtManager.auditor().assetPrice(priceFeedIn));
    return int256(collateral) - int256(debt);
  }

  function floatingBorrowAssets(Market market, address account) internal view returns (uint256) {
    (, , uint256 floatingBorrowShares) = market.accounts(account);
    return market.previewRefund(floatingBorrowShares);
  }
}
