// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BeefySonic} from "../contracts/BeefySonic.sol";
import {IBeefySonic} from "../contracts/interfaces/IBeefySonic.sol";
import {ISFC} from "../contracts/interfaces/ISFC.sol";
import {IConstantsManager} from "../contracts/interfaces/IConstantsManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract BeefySonicInitializationTest is Test {
    BeefySonic public beefySonic;
    BeefySonic public implementation;
    address public want = address(0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38);
    address public stakingContract = address(0xFC00FACE00000000000000000000000000000000);
    address public beefyFeeRecipient = address(0x02Ae4716B9D5d48Db1445814b0eDE39f5c28264B);
    address public keeper = address(0x4fED5491693007f0CD49f4614FFC38Ab6A04B619);
    address public beefyFeeConfig = address(0x2b0C9702A4724f2BFe7922DB92c4082098533c62);
    address public liquidityFeeRecipient = address(0x10E13f11419165beB0F456eC8a230899E4013BBD);
    uint256 public liquidityFee = 0.1e18;
    string public name = "Beefy Sonic";
    string public symbol = "beS";

    function setUp() public {
        vm.createSelectFork({urlOrAlias: "sonic", blockNumber: 13732080});
        implementation = new BeefySonic();
    }

    function test_ProperInitialization() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));
        
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Verify all storage variables are set correctly
        assertEq(beefySonic.asset(), want);
        assertEq(beefySonic.name(), name);
        assertEq(beefySonic.symbol(), symbol);
        assertEq(beefySonic.decimals(), 18);
        assertEq(beefySonic.keeper(), keeper);
        assertEq(beefySonic.beefyFeeConfig(), beefyFeeConfig);
        assertEq(beefySonic.liquidityFee(), liquidityFee);
        
        (address _beefyFeeRecipient, address _liquidityFeeRecipient) = beefySonic.feeRecipients();
        assertEq(_beefyFeeRecipient, beefyFeeRecipient);
        assertEq(_liquidityFeeRecipient, liquidityFeeRecipient);
    }

    function test_PreventDoubleInitialization() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));
        
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Attempt to initialize again
        vm.expectRevert();
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );
    }

    function test_InitializationWithInvalidParameters() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));

        // Test initialization with zero addresses
        vm.expectRevert(IBeefySonic.ZeroAddress.selector);
        beefySonic.initialize(
            address(0),
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        vm.expectRevert(IBeefySonic.ZeroAddress.selector);
        beefySonic.initialize(
            want,
            address(0),
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Test initialization with invalid liquidity fee
        vm.expectRevert(IBeefySonic.InvalidLiquidityFee.selector);
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            0.11e18, // > 10%
            name,
            symbol
        );
    }

    function test_ImplementationInitializationBlocked() public {
        // Attempt to initialize the implementation contract directly
        vm.expectRevert();
        implementation.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );
    }

    function test_InitialStorageSlots() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));
        
        // Check initial values before initialization
        assertEq(beefySonic.totalSupply(), 0);
        assertEq(beefySonic.totalAssets(), 0);
        assertEq(beefySonic.validatorsLength(), 0);
        
        // Initialize contract
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );
        
        // Verify initial state after initialization
        assertEq(beefySonic.totalSupply(), 0);
        assertEq(beefySonic.totalAssets(), 0);
        assertEq(beefySonic.validatorsLength(), 0);
        assertEq(beefySonic.lockDuration(), 1 days);
    }

    function test_OwnershipAfterInitialization() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));
        
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Verify ownership is set to the deployer
        assertEq(beefySonic.owner(), address(this));

        // Test ownership restrictions
        address nonOwner = makeAddr("nonOwner");
        vm.startPrank(nonOwner);
        
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        beefySonic.setBeefyFeeRecipient(nonOwner);
        
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        beefySonic.setLiquidityFeeRecipient(nonOwner);
        
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, nonOwner));
        beefySonic.setLiquidityFee(0.05e18);
        
        vm.stopPrank();
    }

    function test_UpgradeabilityAfterInitialization() public {
        beefySonic = BeefySonic(payable(address(_proxy(address(implementation)))));
        
        beefySonic.initialize(
            want,
            stakingContract,
            beefyFeeRecipient,
            keeper,
            beefyFeeConfig,
            liquidityFeeRecipient,
            liquidityFee,
            name,
            symbol
        );

        // Deploy new implementation
        BeefySonic newImplementation = new BeefySonic();

        // Test upgrade restrictions
        address nonOwner = makeAddr("nonOwner");
        vm.startPrank(nonOwner);
        vm.expectRevert();
        beefySonic.upgradeToAndCall(address(newImplementation), new bytes(0));
        vm.stopPrank();

        // Upgrade as owner
        beefySonic.upgradeToAndCall(address(newImplementation), new bytes(0));
        
        // Verify state is preserved
        assertEq(beefySonic.asset(), want);
        assertEq(beefySonic.name(), name);
        assertEq(beefySonic.symbol(), symbol);
    }

    function _proxy(address _implementation) internal returns (address) {
        bytes memory _empty = "";
        return address(new ERC1967Proxy(address(_implementation), _empty));
    }
} 