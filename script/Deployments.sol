// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// What is deployed, and what each contract is built from.
///
/// The scripts and the upgrade-safety test all read from here, so a proxy and the code
/// meant for it are named together, in one reviewed place, and nobody passes an address
/// on the command line.
///
/// Upgrading a contract (see the README):
///   1. Edit the contract in place, e.g. `src/DataRegistry.sol`. The file and the
///      contract keep their names, so the pull request shows what changed. What it is
///      checked against is the build of the live version, in
///      `deployed/<chain id>/DataRegistry/<implementation address>/`.
///   2. `forge script script/Upgrade.s.sol --force …` upgrades whatever changed.
///      It records the build of the new version next to the old one. Commit it.
library Deployments {
    uint256 internal constant BASE_SEPOLIA = 84532;

    /// Every chain the contracts are deployed on, or may be.
    function chains() internal pure returns (uint256[1] memory) {
        return [BASE_SEPOLIA];
    }

    /// Each contract's source: what a new proxy is deployed with, and what an existing
    /// proxy is upgraded to. Written as `File.sol:Contract`, because a file that also
    /// declares interfaces has more than one artifact.
    string internal constant DATA_REGISTRY = "DataRegistry.sol:DataRegistry";
    string internal constant SETTLEMENT_REGISTRY = "SettlementRegistry.sol:SettlementRegistry";

    error UnknownContract(string name);
    error NoProxyRecorded(string name, uint256 chainId);

    /// Every contract that sits behind a proxy, by the name the scripts take.
    function names() internal pure returns (string[2] memory) {
        return ["DataRegistry", "SettlementRegistry"];
    }

    /// The artifact of `name`, built from its source in `src/`.
    function current(string memory name) internal pure returns (string memory) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("DataRegistry")) return DATA_REGISTRY;
        if (n == keccak256("SettlementRegistry")) return SETTLEMENT_REGISTRY;
        revert UnknownContract(name);
    }

    /// The proxy of `name` on `chainId`: the contract's address, which never changes.
    function proxy(string memory name, uint256 chainId) internal pure returns (address p) {
        p = recorded(name, chainId);
        if (p == address(0)) revert NoProxyRecorded(name, chainId);
    }

    /// The proxy of `name` on `chainId`, or zero while it is not deployed there.
    function recorded(string memory name, uint256 chainId) internal pure returns (address) {
        current(name); // an unknown name is a different mistake from a missing address
        bytes32 n = keccak256(bytes(name));
        if (chainId == BASE_SEPOLIA) {
            // Deployed with Deploy.s.sol all(), in blocks 53592845 to 53592851.
            if (n == keccak256("DataRegistry")) return 0x0F3eb0E62CF610dbaC6B3aD4Bf4cE38Ab50EBCC5;
            if (n == keccak256("SettlementRegistry")) return 0x61A5A195B54F57ada786Ba6689CdB04553cf7fBc;
        }
        return address(0);
    }

    /// The validation options `name` is deployed and upgraded with. None so far: every
    /// contract passes the validator as it is.
    function options(string memory) internal pure returns (Options memory opts) {}

    /// The options `name` is upgraded with: the ones above, plus what the new code is
    /// checked against. That is a build of a version deployed on `chainId`, committed under
    /// `deployed/<chainId>/<name>/<build>/`, and not a second copy of the source: the contract
    /// keeps its file and its name from one version to the next. `build` is the address
    /// of the implementation it is the build of; `Upgrade.s.sol` writes each one.
    function upgradeOptions(string memory name, uint256 chainId, string memory build)
        internal
        pure
        returns (Options memory opts)
    {
        opts = options(name);
        opts.referenceBuildInfoDir = string.concat("deployed/", Strings.toString(chainId), "/", name, "/", build);
        // `<build directory>:<contract>`
        opts.referenceContract = string.concat(build, ":", name);
    }
}
