// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// The builds of deployed versions, committed under
/// `deployed/<Contract>/<implementation address>/`: what the next upgrade of each
/// contract is checked against. Deploy.s.sol writes the first one and Upgrade.s.sol
/// each one after, so nobody builds a reference by hand.
abstract contract Builds is Script {
    /// One place an immutable sits in a contract's runtime code, as solc reports it.
    /// The fields are in alphabetical order, which is how the JSON decodes.
    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

    function _dir(string memory name, address implementation) internal pure returns (string memory) {
        return string.concat("deployed/", name, "/", vm.toString(implementation));
    }

    /// Builds `name` into the directory of `next`, the implementation this run deploys,
    /// and removes every other build of `name` but the one of `live` (none, for a
    /// first deployment: pass the zero address).
    function _record(string memory name, address live, address next) internal {
        string memory parent = string.concat("deployed/", name);
        VmSafe.DirEntry[] memory builds = vm.isDir(parent) ? vm.readDir(parent) : new VmSafe.DirEntry[](0);
        for (uint256 i = 0; i < builds.length; i++) {
            string[] memory path = vm.split(builds[i].path, "/");
            if (keccak256(bytes(path[path.length - 1])) != keccak256(bytes(vm.toString(live)))) {
                vm.removeDir(builds[i].path, true);
            }
        }

        // The same command a reference build was always made with. It gets its own
        // output and cache directories, because --force empties them and this run is
        // still using the usual ones.
        VmSafe.FfiResult memory built = vm.tryFfi(
            vm.split(
                string.concat(
                    "forge build src/",
                    name,
                    ".sol --force --build-info --build-info-path ",
                    _dir(name, next),
                    " --out cache/reference/out --cache-path cache/reference/cache"
                ),
                " "
            )
        );
        require(built.exitCode == 0, string(built.stderr));
        _requireReferenceIsLive(name, next);
    }

    /// Reverts unless the one build in `deployed/<name>/<implementation>/` is the
    /// runtime code at `implementation`, instruction for instruction.
    function _requireReferenceIsLive(string memory name, address implementation) internal view {
        string memory dir = _dir(name, implementation);
        require(
            vm.isDir(dir),
            string.concat(
                dir, " does not exist: no build is recorded for the code that is live. If it was, restore it from git."
            )
        );
        VmSafe.DirEntry[] memory builds = vm.readDir(dir);
        require(builds.length == 1, string.concat(dir, " must hold exactly one build"));
        string memory build = vm.readFile(builds[0].path);
        string memory code = string.concat('.output.contracts["src/', name, '.sol"].', name, ".evm.deployedBytecode");

        bytes memory built = vm.parseJsonBytes(build, string.concat(code, ".object"));
        bytes memory live = implementation.code;
        bool same = live.length == built.length;

        // An immutable is zero in a build and filled in when the contract is created
        // (a UUPS implementation holds its own address), so blank them on the live side.
        string memory immutables = string.concat(code, ".immutableReferences");
        string[] memory ids = vm.parseJsonKeys(build, immutables);
        for (uint256 i = 0; same && i < ids.length; i++) {
            ImmutableRef[] memory refs =
                abi.decode(vm.parseJson(build, string.concat(immutables, '["', ids[i], '"]')), (ImmutableRef[]));
            for (uint256 j = 0; j < refs.length; j++) {
                for (uint256 k = 0; k < refs[j].length; k++) {
                    live[refs[j].start + k] = 0;
                }
            }
        }

        // Both end with solc's metadata: a hash of the source text, comments and all,
        // and its length in the last two bytes. Leave it out, so that a build from
        // source that differs only in a comment still counts as the same code.
        if (same) {
            uint256 n = built.length;
            n -= 2 + (uint256(uint8(built[n - 2])) << 8 | uint8(built[n - 1]));
            assembly {
                mstore(live, n)
                mstore(built, n)
            }
        }

        require(
            same && keccak256(live) == keccak256(built),
            string.concat(
                dir, " is not the code at that address. Rebuild it from the commit that was deployed (README, Upgrade)."
            )
        );
    }
}
