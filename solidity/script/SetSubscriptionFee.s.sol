// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {Deployments} from "./Deployments.sol";

/// Sets what claiming or renewing an app costs. Admin only.
///
///   forge script script/SetSubscriptionFee.s.sol --sig "run(uint256)" 5000000 \
///     --rpc-url <rpc> --account <keystore> --sender <admin address> --broadcast
///
/// The fee is in USDC base units: USDC has 6 decimals, so 5000000 is 5 USDC and
/// 2500000 is 2.5.
contract SetSubscriptionFee is Script {
    function run(uint256 fee) external {
        AppRegistry apps = AppRegistry(Deployments.proxy("AppRegistry", block.chainid));
        uint256 previous = apps.subscriptionFee();

        vm.startBroadcast();
        apps.setSubscriptionFee(fee);
        vm.stopBroadcast();

        require(apps.subscriptionFee() == fee, "fee was not set");
        console.log("AppRegistry subscription fee: %s -> %s USDC base units", previous, fee);
    }
}
