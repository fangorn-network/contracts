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
/// Each deployed one's storage is compared with every build of that contract committed
/// under `deployed/<chain id>/`: a moved, retyped or removed slot fails the test. That is the live
/// version and, after an upgrade, the one it replaced. Which of the two is live cannot
/// be told without the chain, and code that is safe from both is safe from the live one.
///
/// A contract has builds on a chain exactly when Deployments.sol records its proxy there: a deployed
/// contract with no build would go unchecked, and a build with no proxy is left over
/// from a deployment nobody recorded. One not deployed yet has no storage to keep, and
/// is only checked for what makes a contract unsafe behind a proxy at all.
///
/// The validator needs a full build. If this fails with "not from a full compilation",
/// run `forge clean` and try again.
contract UpgradeSafetyTest is Test {
    function test_current_versions_are_upgrade_safe() public {
        string[3] memory names = Deployments.names();
        uint256[1] memory chains = Deployments.chains();
        for (uint256 i = 0; i < names.length; i++) {
            // Safe behind a proxy at all, whether or not it is deployed anywhere yet.
            Upgrades.validateImplementation(Deployments.current(names[i]), Deployments.options(names[i]));
            for (uint256 c = 0; c < chains.length; c++) {
                string memory chain = vm.toString(chains[c]);
                string memory dir = string.concat("deployed/", chain, "/", names[i]);
                VmSafe.DirEntry[] memory builds = vm.isDir(dir) ? vm.readDir(dir) : new VmSafe.DirEntry[](0);
                bool deployed = Deployments.recorded(names[i], chains[c]) != address(0);
                assertEq(
                    builds.length != 0,
                    deployed,
                    string.concat(names[i], " on ", chain, ": builds and proxy address disagree")
                );
                for (uint256 j = 0; j < builds.length; j++) {
                    string[] memory path = vm.split(builds[j].path, "/");
                    _validateUpgrade(names[i], chains[c], path[path.length - 1]);
                }
            }
        }
    }

    /// Each validation reads a build of several megabytes into memory, which Solidity
    /// never frees, so a few in a row run out (MemoryOOG). Nothing it allocates is used
    /// after it returns, so hand the memory back (as Builds.sol does).
    function _validateUpgrade(string memory name, uint256 chainId, string memory build) internal {
        uint256 freeMemory;
        assembly {
            freeMemory := mload(0x40)
        }
        Upgrades.validateUpgrade(Deployments.current(name), Deployments.upgradeOptions(name, chainId, build));
        assembly {
            mstore(0x40, freeMemory)
        }
    }
}
