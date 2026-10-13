// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
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
contract Upgrade is Script {
    /// One place an immutable sits in a contract's runtime code, as solc reports it.
    /// The fields are in alphabetical order, which is how the JSON decodes.
    struct ImmutableRef {
        uint256 length;
        uint256 start;
    }

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

    function _dir(string memory name, address implementation) internal pure returns (string memory) {
        return string.concat("deployed/", name, "/", vm.toString(implementation));
    }

    /// Builds `name` into the directory of `next`, the implementation this run deploys,
    /// and removes every other build of `name` but the one of `live`.
    function _record(string memory name, address live, address next) internal {
        VmSafe.DirEntry[] memory builds = vm.readDir(string.concat("deployed/", name));
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
