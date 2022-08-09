import { expect } from "chai";
import { ethers, deployments, config } from "hardhat";
import type { Contract } from "ethers";
import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import type {
  Auditor,
  Auditor__factory,
  Market,
  Market__factory,
  MockERC20,
  ProxyAdmin,
  TransparentUpgradeableProxy,
} from "../types";
import timelockExecute from "./utils/timelockExecute";

const {
  constants: { AddressZero },
  utils: { parseUnits },
  getContractFactory,
  getNamedSigner,
  getContract,
} = ethers;

const { fixture, get } = deployments;

describe("Auditor Admin", function () {
  let dai: MockERC20;
  let auditor: Auditor;
  let marketDAI: Market;
  let deployer: SignerWithAddress;
  let multisig: SignerWithAddress;

  before(async () => {
    deployer = await getNamedSigner("deployer");
    multisig = await getNamedSigner("multisig");
  });

  beforeEach(async () => {
    await fixture("Markets");

    dai = await getContract<MockERC20>("DAI", deployer);
    auditor = await getContract<Auditor>("Auditor", deployer);
    marketDAI = await getContract<Market>("MarketDAI", deployer);

    await dai.connect(multisig).mint(deployer.address, "10000");
  });

  describe("GIVEN a regular account", () => {
    it("WHEN trying to enable a market, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.enableMarket(marketDAI.address, 0, await dai.decimals())).to.be.revertedWith(
        "AccessControl",
      );
    });

    it("WHEN trying to set liquidation incentive, THEN the transaction should revert with Access Control", async () => {
      await expect(
        auditor.setLiquidationIncentive({ liquidator: parseUnits("0.05"), lenders: parseUnits("0.01") }),
      ).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set a new oracle, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.be.revertedWith("AccessControl");
    });

    it("WHEN trying to set adjust factor, THEN the transaction should revert with Access Control", async () => {
      await expect(auditor.setAdjustFactor(marketDAI.address, 1)).to.be.revertedWith("AccessControl");
    });
  });

  describe("GIVEN the ADMIN/multisig account", () => {
    beforeEach(async () => {
      const ADMIN_ROLE = await auditor.DEFAULT_ADMIN_ROLE();
      expect(await auditor.hasRole(ADMIN_ROLE, multisig.address)).to.equal(false);
      expect(await marketDAI.hasRole(ADMIN_ROLE, multisig.address)).to.equal(false);

      await timelockExecute(multisig, auditor, "grantRole", [ADMIN_ROLE, multisig.address]);

      auditor = auditor.connect(multisig);
    });

    it("WHEN trying to enable a market for the second time, THEN the transaction should revert with MarketAlreadyListed", async () => {
      await expect(auditor.enableMarket(marketDAI.address, 0, await dai.decimals())).to.be.revertedWith(
        "MarketAlreadyListed()",
      );
    });

    it("WHEN trying to set a new market with a different auditor, THEN the transaction should revert with AuditorMismatch", async () => {
      const newAuditor = await ((await getContractFactory("Auditor")) as Auditor__factory).deploy();
      const market = await ((await getContractFactory("Market")) as Market__factory).deploy(
        dai.address,
        newAuditor.address,
      );
      await expect(auditor.enableMarket(market.address, parseUnits("0.5"), await dai.decimals())).to.be.revertedWith(
        "AuditorMismatch()",
      );
    });

    it("WHEN trying to retrieve all markets, THEN the addresses should match the ones passed on deploy", async () => {
      expect(await auditor.allMarkets()).to.deep.equal(
        await Promise.all(config.finance.assets.map(async (symbol) => (await get(`Market${symbol}`)).address)),
      );
    });

    it("WHEN trying to set a new market, THEN the auditor should emit MarketListed event", async () => {
      const market = await ((await getContractFactory("Market")) as Market__factory).deploy(
        dai.address,
        auditor.address,
      );
      await expect(auditor.enableMarket(market.address, parseUnits("0.5"), 18))
        .to.emit(auditor, "MarketListed")
        .withArgs(market.address, 18);
    });

    it("WHEN setting new oracle, THEN the auditor should emit OracleSet event", async () => {
      await expect(auditor.setOracle((await get("ExactlyOracle")).address)).to.emit(auditor, "OracleSet");
    });

    it("WHEN setting a new liquidation incentive, THEN the auditor should emit LiquidationIncentiveSet event", async () => {
      const incentive = { liquidator: parseUnits("0.05"), lenders: parseUnits("0.01") };
      await expect(auditor.setLiquidationIncentive(incentive)).to.emit(auditor, "LiquidationIncentiveSet");
      expect(await auditor.liquidationIncentive()).to.deep.eq([incentive.liquidator, incentive.lenders]);
    });

    it("WHEN setting adjust factor, THEN the auditor should emit AdjustFactorSet event", async () => {
      await expect(auditor.setAdjustFactor(marketDAI.address, parseUnits("0.7")))
        .to.emit(auditor, "AdjustFactorSet")
        .withArgs(marketDAI.address, parseUnits("0.7"));
      expect((await auditor.markets(marketDAI.address)).adjustFactor).to.equal(parseUnits("0.7"));
    });
  });

  describe("Upgradeable", () => {
    let proxy: TransparentUpgradeableProxy;
    let proxyAdmin: ProxyAdmin;
    let newAuditor: Auditor;

    beforeEach(async () => {
      proxy = auditor as Contract as TransparentUpgradeableProxy;
      proxyAdmin = await getContract<ProxyAdmin>("ProxyAdmin", deployer);
      newAuditor = await ((await getContractFactory("Auditor")) as Auditor__factory).deploy();
    });

    it("WHEN trying to initialize implementation, THEN the transaction should revert with Initializable", async () => {
      await expect(newAuditor.initialize(AddressZero, { liquidator: 0, lenders: 0 })).to.be.revertedWith(
        "Initializable: contract is already initialized",
      );
    });

    it("WHEN regular user tries to upgrade, THEN the transaction should revert with not found", async () => {
      await expect(proxy.upgradeTo(newAuditor.address)).to.be.revertedWith(
        "function selector was not recognized and there's no fallback function",
      );
      await expect(proxy.connect(multisig).upgradeTo(newAuditor.address)).to.be.revertedWith(
        "function selector was not recognized and there's no fallback function",
      );
    });

    it("WHEN regular user tries to upgrade through proxy admin, THEN the transaction should revert with Ownable", async () => {
      await expect(proxyAdmin.upgrade(proxy.address, newAuditor.address)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(proxyAdmin.connect(multisig).upgrade(proxy.address, newAuditor.address)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
    });

    it("WHEN timelock tries to upgrade directly, THEN the transaction should revert with not found", async () => {
      await expect(timelockExecute(multisig, auditor, "upgradeTo", [newAuditor.address])).to.be.reverted;
    });

    it("WHEN timelock tries to upgrade through proxy admin, THEN the proxy should emit Upgraded event", async () => {
      await expect(timelockExecute(multisig, proxyAdmin, "upgrade", [proxy.address, newAuditor.address]))
        .to.emit(proxy, "Upgraded")
        .withArgs(newAuditor.address);
    });
  });
});
