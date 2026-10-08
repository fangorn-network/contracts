// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Deployments} from "../script/Deployments.sol";

/// Runs the OpenZeppelin upgrade-safety validation on the current version of every
/// proxied contract, so an unsafe change fails here, on the pull request, and not when
/// someone runs the upgrade.
///
/// A version with an `oz-upgrades-from` annotation is also compared with the storage of
/// the version it names: a moved, retyped or removed slot fails the test.
///
/// The validator needs a full build. If this fails with "not from a full compilation",
/// run `forge clean` and try again.
contract UpgradeSafetyTest is Test {
    function test_current_versions_are_upgrade_safe() public {
        string[3] memory names = Deployments.names();
        for (uint256 i = 0; i < names.length; i++) {
            Upgrades.validateImplementation(Deployments.current(names[i]), Deployments.options(names[i]));
        }
    }
}
