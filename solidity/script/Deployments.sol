// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
///      `deployed/DataRegistry/<implementation address>/`.
///   2. `forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force …`
///      It records the build of the new version next to the old one. Commit it.
library Deployments {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    /// Each contract's source: what a new proxy is deployed with, and what an existing
    /// proxy is upgraded to. Written as `File.sol:Contract`, because a file that also
    /// declares interfaces has more than one artifact.
    string internal constant APP_REGISTRY = "AppRegistry.sol:AppRegistry";
    string internal constant DATA_REGISTRY = "DataRegistry.sol:DataRegistry";
    string internal constant MEMBERSHIP_REGISTRY = "MembershipRegistry.sol:MembershipRegistry";

    error UnknownContract(string name);
    error NoProxyRecorded(string name, uint256 chainId);

    /// Every contract that sits behind a proxy, by the name the scripts take.
    function names() internal pure returns (string[3] memory) {
        return ["AppRegistry", "DataRegistry", "MembershipRegistry"];
    }

    /// The artifact of `name`, built from its source in `src/`.
    function current(string memory name) internal pure returns (string memory) {
        bytes32 n = keccak256(bytes(name));
        if (n == keccak256("AppRegistry")) return APP_REGISTRY;
        if (n == keccak256("DataRegistry")) return DATA_REGISTRY;
        if (n == keccak256("MembershipRegistry")) return MEMBERSHIP_REGISTRY;
        revert UnknownContract(name);
    }

    /// The proxy of `name` on `chainId`: the contract's address, which never changes.
    function proxy(string memory name, uint256 chainId) internal pure returns (address) {
        bytes32 n = keccak256(bytes(name));
        if (chainId == ARBITRUM_SEPOLIA) {
            if (n == keccak256("AppRegistry")) return 0x57b41E334864B430db44F7FbCD8d165C56e41402;
            if (n == keccak256("DataRegistry")) return 0x0312503913656f25c2bfDf229425aA6926ccF1Cd;
            if (n == keccak256("MembershipRegistry")) return 0x57B95b9B20C31E146aDF619Dafc4539e056360a5;
        }
        current(name); // an unknown name is a different mistake from a missing address
        revert NoProxyRecorded(name, chainId);
    }

    /// The validation options `name` is deployed and upgraded with.
    function options(string memory name) internal pure returns (Options memory opts) {
        // MembershipRegistry inherits OpenZeppelin's ERC721 and EIP712, which have
        // constructors, and the validator has no annotation for inherited code. They
        // are safe here: `name` and `symbol` are overridden, so what ERC721's
        // constructor stores is never read, and EIP712 keeps its values in immutables,
        // which a proxy reads from the implementation's code. The contract is live
        // with this storage, so its bases cannot be swapped for the upgradeable ones.
        if (keccak256(bytes(name)) == keccak256("MembershipRegistry")) opts.unsafeAllow = "constructor";
    }

    /// The options `name` is upgraded with: the ones above, plus what the new code is
    /// checked against. That is a build of a deployed version, committed under
    /// `deployed/<name>/<build>/`, and not a second copy of the source: the contract
    /// keeps its file and its name from one version to the next. `build` is the address
    /// of the implementation it is the build of; `Upgrade.s.sol` writes each one.
    // ponytail: one chain. Add the chain id to the path when a second one is deployed.
    function upgradeOptions(string memory name, string memory build) internal pure returns (Options memory opts) {
        opts = options(name);
        opts.referenceBuildInfoDir = string.concat("deployed/", name, "/", build);
        // `<build directory>:<contract>`
        opts.referenceContract = string.concat(build, ":", name);
    }
}
