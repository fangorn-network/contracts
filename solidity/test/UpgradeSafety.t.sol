// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Deployments} from "../script/Deployments.sol";

/// Runs the OpenZeppelin upgrade-safety validation on the current version of every
/// proxied contract, so an unsafe change fails here, on the pull request, and not when
/// someone runs the upgrade.
///
/// Each one's storage is also compared with the build of that contract that is live,
/// committed under `deployed/`: a moved, retyped or removed slot fails the test, whether
/// it came from a new version or from an edit to the deployed one.
///
/// The validator needs a full build. If this fails with "not from a full compilation",
/// run `forge clean` and try again.
contract UpgradeSafetyTest is Test {
    function test_current_versions_are_upgrade_safe() public {
        string[3] memory names = Deployments.names();
        for (uint256 i = 0; i < names.length; i++) {
            Options memory opts = Deployments.options(names[i]);
            opts.referenceBuildInfoDir = string.concat("deployed/", names[i]);
            opts.referenceContract = Deployments.deployed(names[i]);
            Upgrades.validateImplementation(Deployments.current(names[i]), opts);
        }
    }
}
