// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Deployments} from "./Deployments.sol";

/// Carries the quest app over from the previous Base Sepolia deployment (AppRegistry
/// 0x4010ee3a2182D5Ab76E0bf95C17b88bb35Ea711B, DataRegistry
/// 0x5f0B6f0D3ca6266b06fb55CCE5725EB4770dbeFd) into the proxies in Deployments.sol:
/// the app, its agent card, and the owner's `quest` repo head, as of block 51450559.
/// It had no other publishers, renames or exclusions.
///
///   forge script script/Migrate.s.sol --rpc-url https://sepolia.base.org \
///     --account <keystore> --sender 0x951f9e73FA32A83246782edb659ae1669C035BdF --broadcast
///
/// Rerunning skips what is already done. The head restarts at position 1: the old
/// update log stays on the old DataRegistry.
contract Migrate is Script {
    address constant OWNER = 0x951f9e73FA32A83246782edb659ae1669C035BdF;
    bytes32 constant QUEST = 0xbaf0051bf1d22f68cd1d0a93b6252ac00def0ea9bbecc2e4ddc8605ef8ab5c45;
    string constant AGENT_URI = "https://quest.fangorn.network/.well-known/agent-card.json";
    string constant REPO = "quest";
    bytes32 constant HEAD = 0x48095c8580046657167d16b367590e09ab1c93c8840f169b6e453121ed404d02;

    function run() external {
        require(msg.sender == OWNER, "--sender must be quest's owner");
        AppRegistry apps = AppRegistry(Deployments.proxy("AppRegistry", block.chainid));
        DataRegistry data = DataRegistry(Deployments.proxy("DataRegistry", block.chainid));
        (, bytes32 current) = data.getHead(OWNER, keccak256(bytes(REPO)));
        require(current == bytes32(0) || current == HEAD, "quest repo already moved past the snapshot");

        vm.startBroadcast();
        if (apps.getAppOwner(QUEST) == address(0)) {
            uint256 fee = apps.subscriptionFee();
            if (fee != 0) IERC20(apps.usdc()).approve(address(apps), fee);
            apps.registerApp(QUEST, fee);
        }
        if (keccak256(bytes(apps.appAgentUri(QUEST))) != keccak256(bytes(AGENT_URI))) {
            apps.setAppAgentUri(QUEST, AGENT_URI);
        }
        if (current == bytes32(0)) data.update(REPO, bytes32(0), HEAD);
        vm.stopBroadcast();

        console.log("quest migrated: owner %s, head %s", apps.getAppOwner(QUEST), vm.toString(HEAD));
    }
}
