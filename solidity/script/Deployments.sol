// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// What is deployed, and which version of each contract is current.
///
/// The scripts and the upgrade-safety test all read from here, so a proxy and the code
/// meant for it are named together, in one reviewed place, and nobody passes an address
/// on the command line.
///
/// Upgrading a contract (see the README):
///   1. Add the new version as a NEW file and contract, e.g. `src/DataRegistryV2.sol`,
///      carrying the `oz-upgrades-from` annotation that names the version it replaces
///      (the README shows it). Never edit a version that is deployed: its file is the
///      reference the next one is checked against.
///   2. Point the constant below at the new file.
///   3. `forge script script/Upgrade.s.sol --sig "run(string)" DataRegistry --force …`
library Deployments {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    /// The current version of each contract: what a new proxy is deployed with, and what
    /// an existing proxy is upgraded to. Written as `File.sol:Contract`, because a file
    /// that also declares interfaces has more than one artifact.
    string internal constant APP_REGISTRY = "AppRegistry.sol:AppRegistry";
    string internal constant DATA_REGISTRY = "DataRegistry.sol:DataRegistry";
    string internal constant MEMBERSHIP_REGISTRY = "MembershipRegistry.sol:MembershipRegistry";

    error UnknownContract(string name);
    error NoProxyRecorded(string name, uint256 chainId);

    /// Every contract that sits behind a proxy, by the name the scripts take.
    function names() internal pure returns (string[3] memory) {
        return ["AppRegistry", "DataRegistry", "MembershipRegistry"];
    }

    /// The artifact of `name`'s current version.
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
}
