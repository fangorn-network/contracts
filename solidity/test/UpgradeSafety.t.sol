// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Deployments} from "../script/Deployments.sol";

/// Runs the OpenZeppelin upgrade-safety validation on every proxied contract, with the
/// options `Upgrade.s.sol` uses, so an unsafe change fails here, on the pull request, and
/// not when someone runs the upgrade.
///
/// Each one's storage is compared with every build of that contract committed under
/// `deployed/`: a moved, retyped or removed slot fails the test. That is the live
/// version and, after an upgrade, the one it replaced. Which of the two is live cannot
/// be told without the chain, and code that is safe from both is safe from the live one.
///
/// The validator needs a full build. If this fails with "not from a full compilation",
/// run `forge clean` and try again.
contract UpgradeSafetyTest is Test {
    function test_current_versions_are_upgrade_safe() public {
        string[3] memory names = Deployments.names();
        for (uint256 i = 0; i < names.length; i++) {
            VmSafe.DirEntry[] memory builds = vm.readDir(string.concat("deployed/", names[i]));
            assertGt(builds.length, 0, names[i]);
            for (uint256 j = 0; j < builds.length; j++) {
                string[] memory path = vm.split(builds[j].path, "/");
                Upgrades.validateUpgrade(
                    Deployments.current(names[i]), Deployments.upgradeOptions(names[i], path[path.length - 1])
                );
            }
        }
    }
}
