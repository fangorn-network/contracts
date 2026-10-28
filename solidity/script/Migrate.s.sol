// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Deployments} from "./Deployments.sol";

/// Replays the Base Sepolia state of the previous deployment (AppRegistry
/// 0x4010ee3a2182D5Ab76E0bf95C17b88bb35Ea711B, DataRegistry
/// 0x5f0B6f0D3ca6266b06fb55CCE5725EB4770dbeFd) into the proxies in Deployments.sol.
/// Snapshot taken at block 51450559: three apps, one extra publisher, six repo heads.
/// No renames, exclusions, suspensions or memberships existed.
///
/// Each wallet signs for its own apps and repos, so run it once per wallet:
///
///   forge script script/Migrate.s.sol --rpc-url https://sepolia.base.org \
///     --account <keystore> --sender <wallet> --broadcast
///
/// Owners before publishers: 0x7b16… registers codex before 0x1903… is accepted into
/// it, but 0x1903…'s heads do not depend on that. Rerunning skips what is already done.
///
/// Heads restart at position 1: the old update log stays on the old DataRegistry.
contract Migrate is Script {
    address constant QUEST_MUSIC_OWNER = 0x951f9e73FA32A83246782edb659ae1669C035BdF;
    address constant CODEX_OWNER = 0x7b16387C5A8c514880E48bcacd52782FCF9Da936;
    address constant CODEX_PUBLISHER = 0x1903B0D771Ce7cDDC94a70d73537Ca2B5080400b;

    bytes32 constant QUEST = 0xbaf0051bf1d22f68cd1d0a93b6252ac00def0ea9bbecc2e4ddc8605ef8ab5c45;
    bytes32 constant CODEX = 0xfc2842abee091c4475aa6d198884345aa7d07a7dee8da1a8806a67ef276f0dae;
    bytes32 constant MUSIC = 0x14cff0bd4472d1c1d6b5bf51cea683043c58c53c980f006d3c572a96e9681338;

    AppRegistry apps;
    DataRegistry data;

    function run() external {
        apps = AppRegistry(Deployments.proxy("AppRegistry", block.chainid));
        data = DataRegistry(Deployments.proxy("DataRegistry", block.chainid));
        address me = msg.sender;

        vm.startBroadcast();
        if (me == QUEST_MUSIC_OWNER) {
            _app(QUEST, "https://quest.fangorn.network/.well-known/agent-card.json");
            _app(MUSIC, "https://music.fangorn.network/.well-known/agent-card.json");
            _head("quest", 0x48095c8580046657167d16b367590e09ab1c93c8840f169b6e453121ed404d02);
            _head("audius-tracks", 0x280f9a7bfb4f66cf990301639ab91b13406e7a7c1faf1e488fe5ba4e4e77e476);
        } else if (me == CODEX_OWNER) {
            _app(CODEX, "https://codex.fangorn-0be.workers.dev/.well-known/agent-card.json");
            if (apps.statusForApp(CODEX, CODEX_PUBLISHER) == AppRegistry.Status.None) {
                apps.acceptPublisher(CODEX, CODEX_PUBLISHER);
            }
            _head("findings", 0xaf4e34f3efb2fde17426b39b0bb8c4c4387d2e3f29151fc08ce31b2733dfbcd0);
            _head("research", 0x0626c538efcf243182ca05012a22253b2b3ee59969c13dd2e382f6c0b810815c);
        } else if (me == CODEX_PUBLISHER) {
            _head("findings-tony", 0x2958ae9f79538ba24d1b7613b28cba2b6eb83462a50badc95d5c715502a39aa5);
            _head("research", 0xd1be3cb3369219284245ac22c8914950c66df3142e549b7d09ccb7c6f1f56dda);
        } else {
            revert("nothing to migrate for this --sender");
        }
        vm.stopBroadcast();
    }

    function _app(bytes32 id, string memory agentUri) internal {
        if (apps.getAppOwner(id) == address(0)) {
            uint256 fee = apps.subscriptionFee();
            if (fee != 0) IERC20(apps.usdc()).approve(address(apps), fee);
            apps.registerApp(id, fee);
        }
        if (keccak256(bytes(apps.appAgentUri(id))) != keccak256(bytes(agentUri))) apps.setAppAgentUri(id, agentUri);
        console.log("app %s", vm.toString(id));
    }

    function _head(string memory repo, bytes32 head) internal {
        (, bytes32 current) = data.getHead(msg.sender, keccak256(bytes(repo)));
        if (current == bytes32(0)) data.update(repo, bytes32(0), head);
        else require(current == head, string.concat(repo, ": already moved past the snapshot"));
        console.log("repo %s", repo);
    }
}
