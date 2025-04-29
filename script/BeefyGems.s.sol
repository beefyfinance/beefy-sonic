// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BeefyGemsFactory} from "../contracts/gems/BeefyGemsFactory.sol";
import {BeefyGems} from "../contracts/gems/BeefyGems.sol";

contract BeefyGemsScript is Script {

    address public treasury = address(0x10E13f11419165beB0F456eC8a230899E4013BBD);

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        BeefyGemsFactory factory = new BeefyGemsFactory(treasury);
        console.log("BeefyGemsFactory deployed to:", address(factory));

        address gems = factory.createSeason(80_000_000e18);
        console.log("BeefyGems deployed to:", gems);

        factory.transferOwnership(treasury);
        
        vm.stopBroadcast();
    }
}