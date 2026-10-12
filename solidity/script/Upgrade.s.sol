// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Deployments} from "./Deployments.sol";

/// Upgrades one deployed contract in place, to its current version in `Deployments`.
///
///   forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
///     --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
///
/// `--force` is not optional: the upgrade-safety check needs a full build.
///
/// `name` is AppRegistry, DataRegistry or MembershipRegistry. The proxy's address and
/// state stay; only the implementation behind it changes.
///
/// Before anything is sent, the plugin checks the new version against the one named in
/// its `oz-upgrades-from` annotation: a moved, retyped or removed storage slot stops
/// the upgrade, and so does a version that names no predecessor. The signer must be the
/// contract's admin, or the simulation reverts and nothing is sent either.
contract Upgrade is Script {
    function run(string calldata name) external {
        run(name, "");
    }

    /// `data` is a call to make on the new implementation in the upgrade transaction,
    /// for an upgrade that has to set up new state (a `reinitializer` function).
    function run(string calldata name, bytes memory data) public {
        address proxy = Deployments.proxy(name, block.chainid);
        string memory version = Deployments.current(name);
        address previous = Upgrades.getImplementationAddress(proxy);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, version, data, Deployments.options(name));
        vm.stopBroadcast();

        console.log("%s at %s is now %s", name, proxy, version);
        console.log("  implementation: %s (was %s)", Upgrades.getImplementationAddress(proxy), previous);
    }
}
