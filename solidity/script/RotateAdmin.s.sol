// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Deployments} from "./Deployments.sol";

/// The two calls every registry has.
interface IAdmin {
    function admin() external view returns (address);
    function setAdmin(address new_admin) external;
}

/// Moves the admin of all three registries from the current admin to `newAdmin`, in one
/// broadcast. Run it as the current admin:
///
///   forge script script/RotateAdmin.s.sol --sig "run(address)" <new admin> \
///     --rpc-url <rpc> --account <keystore> --sender <current admin> --broadcast
///
/// Each registry keeps its own admin, so they could drift apart. Before sending anything,
/// this checks that all three still name the admin recorded below for the chain. Once it
/// has run, update that address to the new admin.
contract RotateAdmin is Script {
    address internal constant BASE_SEPOLIA_ADMIN = 0x7b16387C5A8c514880E48bcacd52782FCF9Da936;

    function run(address newAdmin) external {
        // Zero would renounce the admin role, and with it every future upgrade. Use
        // setAdmin directly if that is really the intent.
        require(newAdmin != address(0), "new admin is the zero address");
        address current = currentAdmin();
        string[3] memory names = Deployments.names();

        for (uint256 i; i < names.length; i++) {
            require(_registry(names[i]).admin() == current, string.concat(names[i], ": admin is not the recorded one"));
        }

        vm.startBroadcast();
        for (uint256 i; i < names.length; i++) {
            _registry(names[i]).setAdmin(newAdmin);
        }
        vm.stopBroadcast();

        for (uint256 i; i < names.length; i++) {
            require(_registry(names[i]).admin() == newAdmin, string.concat(names[i], ": admin was not set"));
            console.log("%s admin: %s -> %s", names[i], current, newAdmin);
        }
    }

    function currentAdmin() public view returns (address) {
        if (block.chainid == Deployments.BASE_SEPOLIA) return BASE_SEPOLIA_ADMIN;
        revert("no admin recorded for this chain");
    }

    function _registry(string memory name) internal view returns (IAdmin) {
        return IAdmin(Deployments.proxy(name, block.chainid));
    }
}
