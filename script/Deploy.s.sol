// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {SettlementRegistry} from "../src/SettlementRegistry.sol";
import {Builds} from "./Builds.sol";
import {Deployments} from "./Deployments.sol";

/// Deploys the Fangorn contracts, each behind its own ERC-1967 proxy (UUPS).
///
///   forge script script/Deploy.s.sol --sig "all()" --force \
///     --rpc-url <rpc> --account <keystore> --sender <deployer address> --broadcast
///
/// `--force` is not optional: the upgrade-safety check needs a full build.
///
///   all()                 every registry
///   dataRegistry()
///   settlementRegistry()
///
/// With --broadcast, each new contract's build is written under
/// `deployed/<chain id>/<Contract>/<implementation address>/`, replacing any older build of it: the
/// first upgrade is checked against it. Commit it with the broadcast log and the new
/// addresses in Deployments.sol.
///
/// This is for a FIRST deployment. To change a contract that is already deployed, use
/// Upgrade.s.sol: it keeps the address and the state. A redeploy starts empty at a new
/// address.
///
/// The whole run is simulated before anything is sent, so a failed check below stops it
/// with nothing deployed.
///
/// Parameters are environment variables (Forge also reads a `.env` in this directory):
///   ADMIN_ADDR              required. Takedowns and upgrades.
///   USDC_ADDR, SEMAPHORE_ADDR
///                           default to Base Sepolia's; required on any other chain
contract Deploy is Builds {
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    /// Semaphore v4
    address internal constant SEMAPHORE = 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D;

    function all() external {
        address admin = _admin();
        vm.startBroadcast();
        DataRegistry data = _deployDataRegistry(admin);
        address settlement = _deploySettlementRegistry(admin);
        vm.stopBroadcast();
        _report(data);
        _reportSettlement(settlement, admin);
        _recordBuild("DataRegistry", address(data));
        _recordBuild("SettlementRegistry", settlement);
    }

    function dataRegistry() external {
        address admin = _admin();
        vm.startBroadcast();
        DataRegistry data = _deployDataRegistry(admin);
        vm.stopBroadcast();
        _report(data);
        _recordBuild("DataRegistry", address(data));
    }

    function settlementRegistry() external {
        address admin = _admin();
        vm.startBroadcast();
        address proxy = _deploySettlementRegistry(admin);
        vm.stopBroadcast();
        _reportSettlement(proxy, admin);
        console.log("Record it in script/Deployments.sol.");
        _recordBuild("SettlementRegistry", proxy);
    }

    // ── Steps ─────────────────────────────────────────────────────────────────

    function _deployDataRegistry(address admin) internal returns (DataRegistry) {
        return DataRegistry(
            Upgrades.deployUUPSProxy(
                Deployments.DATA_REGISTRY,
                abi.encodeCall(DataRegistry.initialize, (admin)),
                Deployments.options("DataRegistry")
            )
        );
    }

    function _deploySettlementRegistry(address admin) internal returns (address) {
        return Upgrades.deployUUPSProxy(
            Deployments.SETTLEMENT_REGISTRY,
            abi.encodeCall(SettlementRegistry.initialize, (admin, _usdc(), _semaphore())),
            Deployments.options("SettlementRegistry")
        );
    }

    function _report(DataRegistry data) internal view {
        require(data.admin() == _admin(), "DataRegistry admin");
        console.log("DataRegistry: %s", address(data));
        console.log("Record the new address(es) in script/Deployments.sol.");
    }

    function _reportSettlement(address proxy, address admin) internal view {
        SettlementRegistry settlement = SettlementRegistry(proxy);
        require(settlement.admin() == admin, "SettlementRegistry admin");
        require(settlement.usdc() == _usdc(), "SettlementRegistry usdc");
        require(settlement.semaphore() == _semaphore(), "SettlementRegistry semaphore");
        console.log("SettlementRegistry: %s", proxy);
    }

    /// With --broadcast, writes the build of `proxy`'s implementation under `deployed/`
    /// (see the top of this file). A dry run writes nothing.
    function _recordBuild(string memory name, address proxy) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        address implementation = Upgrades.getImplementationAddress(proxy);
        _record(name, address(0), implementation);
        console.log("Build of %s: %s", name, _dir(name, implementation));
    }

    // ── Parameters ────────────────────────────────────────────────────────────

    /// No default: the admin can take subjects down and upgrade the contracts,
    /// so it is never chosen for the caller. Zero is refused: nobody could upgrade.
    function _admin() internal view returns (address admin) {
        admin = vm.envAddress("ADMIN_ADDR");
        require(admin != address(0), "ADMIN_ADDR is the zero address");
    }

    function _usdc() internal view returns (address) {
        return _external("USDC_ADDR", BASE_SEPOLIA_USDC);
    }

    function _semaphore() internal view returns (address) {
        return _external("SEMAPHORE_ADDR", SEMAPHORE);
    }

    /// An address this deployment depends on. The known ones are only defaults on the
    /// chain they belong to; anywhere else it has to be given.
    function _external(string memory name, address onBaseSepolia) private view returns (address) {
        if (block.chainid == Deployments.BASE_SEPOLIA) return vm.envOr(name, onBaseSepolia);
        return vm.envAddress(name);
    }
}
