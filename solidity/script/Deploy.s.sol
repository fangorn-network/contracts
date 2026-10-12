// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {MembershipRegistry} from "../src/MembershipRegistry.sol";
import {Deployments} from "./Deployments.sol";

/// Deploys the Fangorn contracts, each behind its own ERC-1967 proxy (UUPS).
///
///   forge script script/Deploy.s.sol --sig "all()" --force \
///     --rpc-url <rpc> --account <keystore> --sender <deployer address> --broadcast
///
/// `--force` is not optional: the upgrade-safety check needs a full build.
///
///   all()                               AppRegistry and DataRegistry, wired to each
///                                       other, and the default app claimed
///   appRegistry(address dataRegistry)   a new AppRegistry in front of an existing
///                                       DataRegistry, which is repointed at it
///   dataRegistry(address appRegistry)   a new DataRegistry behind an existing
///                                       AppRegistry, which is repointed at it
///   membershipRegistry(address appRegistry)
///
/// This is for a FIRST deployment. To change a contract that is already deployed, use
/// Upgrade.s.sol: it keeps the address and the state. A redeploy starts empty at a new
/// address.
///
/// The whole run is simulated before anything is sent, so a failed check below, or a
/// signer who is not the admin, stops it with nothing deployed.
///
/// Parameters are environment variables (Forge also reads a `.env` in this directory):
///   ADMIN_ADDR              required. Fees, takedowns and upgrades. For all(),
///                           appRegistry() and dataRegistry() it must be the signer,
///                           because the wiring calls are admin-only.
///   USDC_ADDR, SEMAPHORE_ADDR
///                           default to Arbitrum Sepolia's; required on any other chain
///   REGISTRATION_FEE        DataRegistry.register(), in wei. Default 0
///   SUBSCRIPTION_FEE        claiming an app, in USDC base units. Default 0
///   DEFAULT_APP_NAME, DEFAULT_APP_TERMS_HASH, DEFAULT_APP_TERMS_URI,
///   DEFAULT_APP_JOIN_FEE    the app claimed for the deployer. Defaults below
contract Deploy is Script {
    address internal constant SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address internal constant SEPOLIA_SEMAPHORE = 0x8A1fd199516489B0Fb7153EB5f075cDAC83c693D;
    // sha256("test"): a placeholder for testing, with no real significance. An app with
    // a zero terms hash cannot be joined, so the default app needs some value.
    bytes32 internal constant DEFAULT_TERMS_HASH = 0x9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08;

    function all() external {
        address admin = _admin();
        vm.startBroadcast();
        AppRegistry apps = _deployAppRegistry(admin, address(0));
        DataRegistry data = _deployDataRegistry(admin, address(apps));
        // Each registry consults the other. Until this is set the AppRegistry treats
        // every wallet as unregistered, and no app can be claimed.
        apps.setDataRegistry(address(data));
        _claimDefaultApp(apps, data);
        vm.stopBroadcast();
        _report(apps, data);
    }

    function appRegistry(address dataRegistry_) external {
        address admin = _admin();
        DataRegistry data = DataRegistry(dataRegistry_);
        vm.startBroadcast();
        AppRegistry apps = _deployAppRegistry(admin, dataRegistry_);
        // The existing DataRegistry still checks membership against the old AppRegistry.
        // Namespace heads stay; apps and memberships do not carry over.
        data.setAppRegistry(address(apps));
        _claimDefaultApp(apps, data);
        vm.stopBroadcast();
        _report(apps, data);
    }

    function dataRegistry(address appRegistry_) external {
        address admin = _admin();
        AppRegistry apps = AppRegistry(appRegistry_);
        vm.startBroadcast();
        DataRegistry data = _deployDataRegistry(admin, appRegistry_);
        // Registrations and namespace heads do not carry over.
        apps.setDataRegistry(address(data));
        vm.stopBroadcast();
        _report(apps, data);
    }

    /// The AppRegistry is an argument, not a default: the MembershipRegistry has no
    /// setter for it, and it decides who may set an app's plan and who is paid.
    function membershipRegistry(address appRegistry_) external {
        address admin = _admin();
        require(appRegistry_.code.length != 0, "appRegistry has no code on this chain");
        vm.startBroadcast();
        address proxy = Upgrades.deployUUPSProxy(
            Deployments.MEMBERSHIP_REGISTRY,
            abi.encodeCall(MembershipRegistry.initialize, (admin, _usdc(), _semaphore(), appRegistry_)),
            Deployments.options("MembershipRegistry")
        );
        vm.stopBroadcast();

        MembershipRegistry membership = MembershipRegistry(proxy);
        require(membership.admin() == admin, "MembershipRegistry admin");
        require(membership.appRegistry() == appRegistry_, "MembershipRegistry appRegistry");
        console.log("MembershipRegistry: %s", proxy);
        console.log("Record it in script/Deployments.sol.");
    }

    // ── Steps ─────────────────────────────────────────────────────────────────

    function _deployAppRegistry(address admin, address dataRegistry_) internal returns (AppRegistry) {
        return AppRegistry(
            Upgrades.deployUUPSProxy(
                Deployments.APP_REGISTRY,
                abi.encodeCall(
                    AppRegistry.initialize, (admin, _usdc(), vm.envOr("SUBSCRIPTION_FEE", uint256(0)), dataRegistry_)
                ),
                Deployments.options("AppRegistry")
            )
        );
    }

    function _deployDataRegistry(address admin, address appRegistry_) internal returns (DataRegistry) {
        return DataRegistry(
            Upgrades.deployUUPSProxy(
                Deployments.DATA_REGISTRY,
                abi.encodeCall(
                    DataRegistry.initialize, (admin, vm.envOr("REGISTRATION_FEE", uint256(0)), appRegistry_)
                ),
                Deployments.options("DataRegistry")
            )
        );
    }

    /// Claims the default app for the deployer. After the wiring: a claim needs the
    /// claimer to be a registered publisher, and pays the subscription fee.
    function _claimDefaultApp(AppRegistry apps, DataRegistry data) internal {
        bytes32 termsHash = vm.envOr("DEFAULT_APP_TERMS_HASH", DEFAULT_TERMS_HASH);
        // A zero terms hash leaves the app unjoinable, which reads on the website as
        // "registration is broken". Fail here instead, where the cause is obvious.
        require(termsHash != bytes32(0), "DEFAULT_APP_TERMS_HASH is zero: an app with no terms cannot be joined");

        (, address deployer,) = vm.readCallers();
        if (!data.isRegistered(deployer)) data.register{value: data.registrationFee()}();

        uint256 fee = apps.subscriptionFee();
        if (fee != 0) IERC20(apps.usdc()).approve(address(apps), fee);

        bytes32 appId = keccak256(bytes(vm.envOr("DEFAULT_APP_NAME", string("fangorn"))));
        apps.registerApp(
            appId,
            termsHash,
            vm.envOr("DEFAULT_APP_TERMS_URI", string("https://fangorn.network/terms.html")),
            vm.envOr("DEFAULT_APP_JOIN_FEE", uint256(0))
        );
        require(apps.getAppOwner(appId) == deployer, "default app owner");
    }

    function _report(AppRegistry apps, DataRegistry data) internal view {
        address admin = _admin();
        require(apps.admin() == admin, "AppRegistry admin");
        require(data.admin() == admin, "DataRegistry admin");
        require(apps.dataRegistry() == address(data), "AppRegistry does not point at the DataRegistry");
        require(data.appRegistry() == address(apps), "DataRegistry does not point at the AppRegistry");
        console.log("AppRegistry:  %s", address(apps));
        console.log("DataRegistry: %s", address(data));
        console.log("Record the new address(es) in script/Deployments.sol.");
    }

    // ── Parameters ────────────────────────────────────────────────────────────

    /// No default: the admin can change fees, take apps down and upgrade the contracts,
    /// so it is never chosen for the caller. Zero is refused: nobody could upgrade.
    function _admin() internal view returns (address admin) {
        admin = vm.envAddress("ADMIN_ADDR");
        require(admin != address(0), "ADMIN_ADDR is the zero address");
    }

    function _usdc() internal view returns (address) {
        return _external("USDC_ADDR", SEPOLIA_USDC);
    }

    function _semaphore() internal view returns (address) {
        return _external("SEMAPHORE_ADDR", SEPOLIA_SEMAPHORE);
    }

    /// An address this deployment depends on. The known one is only a default on the
    /// chain it belongs to; anywhere else it has to be given.
    function _external(string memory name, address onSepolia) private view returns (address) {
        return block.chainid == Deployments.ARBITRUM_SEPOLIA ? vm.envOr(name, onSepolia) : vm.envAddress(name);
    }
}
