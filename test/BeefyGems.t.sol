// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BeefyGemsFactory} from "../contracts/gems/BeefyGemsFactory.sol";
import {BeefyGems} from "../contracts/gems/BeefyGems.sol";

contract BeefyGemsTest is Test {
    BeefyGemsFactory public factory;
    BeefyGems public implementation;
    address public treasury;

    function setUp() public {
        vm.createSelectFork({urlOrAlias: "sonic", blockNumber: 13732080});

        implementation = new BeefyGems();
        treasury = makeAddr("treasury");
        factory = new BeefyGemsFactory(treasury);
    }

    function test_create_season() public {
        _createSeason(80_000_000e18);
    }

    function test_open_season() public {
        _createSeason(80_000_000e18);
        _openSeason(1, 80_000_000e18 * 2);
    }

    function test_redeem() public {
        _createSeason(80_000_000e18);
        _openSeason(1, 80_000_000e18 * 2);

        address alice = makeAddr("alice");
        vm.startPrank(treasury);
        IERC20(address(factory.getSeason(1).gems)).transfer(alice, 80e18);
        vm.stopPrank();

        vm.startPrank(alice);
        factory.redeem(1, 80e18, alice);
        vm.stopPrank();

        assertEq(IERC20(address(factory.getSeason(1).gems)).balanceOf(address(alice)), 0);
        assertEq(address(alice).balance, 80e18 * 2);
    }

    function test_second_season() public {
        _createSeason(80_000_000e18);
        _openSeason(1, 80_000_000e18 * 2);

        _createSeason(80_000_000e18);
        _openSeason(2, 80_000_000e18 * 2);

        address alice = makeAddr("alice");
        vm.startPrank(treasury);
        IERC20(address(factory.getSeason(2).gems)).transfer(alice, 80e18);
        vm.stopPrank();

        vm.startPrank(alice);
        factory.redeem(2, 40e18, alice);
        BeefyGems(factory.getSeason(2).gems).redeem(40e18);
        vm.stopPrank();

        assertEq(IERC20(address(factory.getSeason(2).gems)).balanceOf(address(alice)), 0);
        assertEq(address(alice).balance, 80e18 * 2);
    }

    function test_redeem_before_season_is_open() public {
        _createSeason(80_000_000e18);

        address alice = makeAddr("alice");
        vm.startPrank(treasury);
        IERC20(address(factory.getSeason(1).gems)).transfer(alice, 80e18);
        vm.stopPrank();

        vm.startPrank(alice);
        vm.expectRevert(BeefyGemsFactory.RedemptionNotOpen.selector);
        factory.redeem(1, 80e18, alice);
        vm.stopPrank();
    }

    function test_top_up_season() public {
        _createSeason(80_000_000e18);
        _openSeason(1, 80_000_000e18 * 2);

        vm.startPrank(factory.owner());
        vm.deal(factory.owner(), 80_000_000e18 * 2);
        factory.topUpSeason{value: 80_000_000e18 * 2}(1);
        vm.stopPrank();

        assertEq(factory.getSeason(1).amountOfS, 80_000_000e18 * 4);
        assertEq(factory.getPriceForFullShare(1), 4e18);
    }

    function test_burn_someone_elses_gems() public {
        _createSeason(80_000_000e18);
        _openSeason(1, 80_000_000e18 * 2);

        address gems = factory.getSeason(1).gems;

        address alice = makeAddr("alice");
        vm.startPrank(treasury);
        IERC20(gems).transfer(alice, 80e18);
        vm.stopPrank();

        address bob = makeAddr("bob");
        vm.startPrank(bob);
        vm.expectRevert();
        BeefyGems(gems).burn(80e18, alice);
        vm.stopPrank();
    }

    function _createSeason(uint256 _amountOfGems) internal {
        vm.startPrank(factory.owner());
        uint256 seasonNum = factory.numSeasons();
        factory.createSeason(_amountOfGems);
        console.log("Season created ", BeefyGems(factory.getSeason(seasonNum + 1).gems).name());
        assertEq(factory.numSeasons(), seasonNum + 1);
        assertEq(BeefyGems(factory.getSeason(seasonNum + 1).gems).totalSupply(), _amountOfGems);
        assertEq(factory.getSeason(seasonNum + 1).amountOfS, 0);
        vm.stopPrank();
    }

    function _openSeason(uint256 _seasonNum, uint256 _amountOfS) internal {
        vm.startPrank(factory.owner());
        vm.deal(factory.owner(), _amountOfS);
        factory.openSeasonRedemption{value: _amountOfS}(_seasonNum);
        assertEq(factory.getSeason(_seasonNum).amountOfS, _amountOfS);
        assertEq(factory.getPriceForFullShare(_seasonNum), 2e18);
        vm.stopPrank();
    }
}