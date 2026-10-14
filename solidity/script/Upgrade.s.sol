// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Builds} from "./Builds.sol";
import {Deployments} from "./Deployments.sol";

/// Upgrades one deployed contract in place, to what its source in `src/` now says.
///
///   forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force \
///     --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
///
/// `--force` is not optional: the upgrade-safety check needs a full build.
///
/// `name` is AppRegistry, DataRegistry or MembershipRegistry. The proxy's address and
/// state stay; only the implementation behind it changes.
///
/// Before anything is sent, the plugin checks the new code against the build of the
/// live version, committed under `deployed/<name>/<implementation address>/`: a moved,
/// retyped or removed storage slot stops the upgrade. The signer must be the contract's
/// admin, or the simulation reverts and nothing is sent either.
///
/// That check is only as good as the build it compares with, so the script first
/// confirms the build IS the code behind the proxy, and refuses to upgrade if it is
/// not. The same confirmation runs on its own, for every contract, with
///
///   forge script script/Upgrade.s.sol --sig "check()" --rpc-url <rpc>
///
/// With `--broadcast` the script also writes the build of the new version, under the
/// address it is deployed at, so the next upgrade has its reference without anyone
/// rebuilding it. It is written next to the live build and not over it, because the
/// script runs before the transactions are sent: if they fail, the live build is still
/// there and the upgrade can be run again. The build of the version before the live one
/// is removed at the same time, so `deployed/<name>/` never holds more than two.
contract Upgrade is Builds {
    function run(string calldata name) external {
        run(name, "");
    }

    /// `data` is a call to make on the new implementation in the upgrade transaction,
    /// for an upgrade that has to set up new state (a `reinitializer` function).
    function run(string calldata name, bytes memory data) public {
        address proxy = Deployments.proxy(name, block.chainid);
        string memory version = Deployments.current(name);
        address previous = Upgrades.getImplementationAddress(proxy);
        _requireReferenceIsLive(name, previous);

        vm.startBroadcast();
        Upgrades.upgradeProxy(proxy, version, data, Deployments.upgradeOptions(name, vm.toString(previous)));
        vm.stopBroadcast();

        address next = Upgrades.getImplementationAddress(proxy);
        console.log("%s at %s is now %s", name, proxy, version);
        console.log("  implementation: %s (was %s)", next, previous);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _record(name, previous, next);
            console.log("Its build is in %s. Commit it with the broadcast log.", _dir(name, next));
        } else {
            console.log("Dry run: nothing sent, and no build recorded.");
        }
    }

    /// Confirms that every build under `deployed/` is the code that is live on this
    /// chain. Sends nothing and needs no signer.
    function check() external view {
        string[3] memory names = Deployments.names();
        for (uint256 i = 0; i < names.length; i++) {
            address implementation = Upgrades.getImplementationAddress(Deployments.proxy(names[i], block.chainid));
            _requireReferenceIsLive(names[i], implementation);
            console.log("deployed/%s is the code at %s", names[i], implementation);
        }
    }
}
