// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BMCToken} from "../src/BMCToken.sol";

contract BMCTokenTest is Test {
    BMCToken token;
    address alice = makeAddr("alice");

    function setUp() public {
        token = new BMCToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "BMC Illuminati");
        assertEq(token.symbol(), "BMC");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.balanceOf(address(this)), token.totalSupply(), "whole supply minted to the deployer");
    }

    function test_transferMovesExactly() public {
        uint256 amount = 12_345 ether;
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1_000_000_000 ether - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether, "a transfer never changes supply");
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintPath() public {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "mint must not exist");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_noOwnerOrPause() public {
        string[4] memory sigs = ["owner()", "pause()", "transferOwnership(address)", "setFee(uint256)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(this)));
            assertFalse(ok, sigs[i]);
        }
    }

    function test_burnReducesSupply() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.burn(40 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether - 40 ether);
    }

    function test_burnMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burn(1);
    }

    function test_burnFromNeedsAllowance() public {
        token.transfer(alice, 100 ether);
        vm.expectRevert();
        token.burnFrom(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(this), 1 ether);
        token.burnFrom(alice, 1 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether - 1 ether);
    }
}
