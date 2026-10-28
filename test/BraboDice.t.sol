// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {BraboDice} from "../src/BraboDice.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract MockBRB {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failTransfers;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!failTransfers, "blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BraboDiceTest is Test {
    BraboDice dice;
    MockBRB brb;
    VRFCoordinatorV2_5Mock vrf;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant BET = 100 ether;

    function setUp() public {
        vrf = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subId = vrf.createSubscription();
        vrf.fundSubscription(subId, 1000 ether);
        brb = new MockBRB();
        dice = new BraboDice(address(brb), address(vrf), subId, bytes32(0));
        vrf.addConsumer(subId, address(dice));

        brb.mint(alice, 1000 ether);
        brb.mint(bob, 1000 ether);
        vm.prank(alice);
        brb.approve(address(dice), type(uint256).max);
        vm.prank(bob);
        brb.approve(address(dice), type(uint256).max);
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vrf.fulfillRandomWordsWithOverride(requestId, address(dice), words);
    }

    function _openGame(uint256 creatorWord) internal returns (uint256 gameId) {
        vm.prank(alice);
        gameId = dice.throwCoin(BET);
        _fulfill(gameId, creatorWord); // mock request ids start at 1, one per request
    }

    function test_SameSide_CreatorWins() public {
        uint256 gameId = _openGame(1); // tails
        assertEq(dice.getOpenGames().length, 1);
        assertEq(dice.getGame(gameId).creatorSide, 1);

        vm.prank(bob);
        dice.acceptChallenge(gameId);
        assertEq(dice.getOpenGames().length, 0);
        _fulfill(2, 3); // tails

        assertEq(brb.balanceOf(alice), 1100 ether);
        assertEq(brb.balanceOf(bob), 900 ether);
        assertEq(dice.getGame(gameId).winner, alice);
        assertEq(uint8(dice.getGame(gameId).status), uint8(BraboDice.Status.Finished));
    }

    function test_DifferentSide_ChallengerWins() public {
        uint256 gameId = _openGame(0); // heads
        vm.prank(bob);
        dice.acceptChallenge(gameId);
        _fulfill(2, 1); // tails

        assertEq(brb.balanceOf(alice), 900 ether);
        assertEq(brb.balanceOf(bob), 1100 ether);
    }

    function test_RefundAfter24h() public {
        uint256 gameId = _openGame(0);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__NotRefundable.selector, gameId));
        dice.refund(gameId);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__GameExpired.selector, gameId));
        dice.acceptChallenge(gameId);

        dice.refund(gameId);
        assertEq(brb.balanceOf(alice), 1000 ether);
        assertEq(dice.getOpenGames().length, 0);
    }

    function test_CannotChallengeOwnGame() public {
        uint256 gameId = _openGame(0);
        vm.prank(alice);
        vm.expectRevert(BraboDice.BraboDice__CannotChallengeOwnGame.selector);
        dice.acceptChallenge(gameId);
    }

    function test_CannotAcceptBeforeCreatorFlip() public {
        vm.prank(alice);
        uint256 gameId = dice.throwCoin(BET);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__GameNotOpen.selector, gameId));
        dice.acceptChallenge(gameId);
    }

    function test_StuckChallengerVrf_RefundsBoth() public {
        uint256 gameId = _openGame(0);
        vm.prank(bob);
        dice.acceptChallenge(gameId);

        vm.warp(block.timestamp + 24 hours + 1);
        dice.refund(gameId);
        assertEq(brb.balanceOf(alice), 1000 ether);
        assertEq(brb.balanceOf(bob), 1000 ether);

        // late VRF answer is ignored
        _fulfill(2, 0);
        assertEq(uint8(dice.getGame(gameId).status), uint8(BraboDice.Status.Refunded));
    }

    function test_FailedPayoutIsDeferred() public {
        uint256 gameId = _openGame(0);
        vm.prank(bob);
        dice.acceptChallenge(gameId);

        brb.setFailTransfers(true);
        _fulfill(2, 0);
        assertEq(dice.s_pendingWithdrawals(alice), 2 * BET);

        brb.setFailTransfers(false);
        vm.prank(alice);
        dice.withdraw();
        assertEq(brb.balanceOf(alice), 1100 ether);
    }

    function test_LobbyTracksMultipleGames() public {
        uint256 g1 = _openGame(0);
        vm.prank(alice);
        uint256 g2 = dice.throwCoin(BET);
        _fulfill(2, 1);

        vm.prank(bob);
        dice.acceptChallenge(g1);
        uint256[] memory open = dice.getOpenGames();
        assertEq(open.length, 1);
        assertEq(open[0], g2);
    }

    // ── Edge cases ──────────────────────────────────────────────────────────

    function test_ZeroAmountReverts() public {
        vm.prank(alice);
        vm.expectRevert(BraboDice.BraboDice__ZeroAmount.selector);
        dice.throwCoin(0);
    }

    function test_CannotAcceptTwice() public {
        uint256 gameId = _openGame(0);
        vm.prank(bob);
        dice.acceptChallenge(gameId);

        address carol = makeAddr("carol");
        brb.mint(carol, BET);
        vm.startPrank(carol);
        brb.approve(address(dice), BET);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__GameNotOpen.selector, gameId));
        dice.acceptChallenge(gameId);
        vm.stopPrank();
    }

    function test_CannotRefundFinished() public {
        uint256 gameId = _openGame(0);
        vm.prank(bob);
        dice.acceptChallenge(gameId);
        _fulfill(2, 0);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__NotRefundable.selector, gameId));
        dice.refund(gameId);
    }

    function test_RefundTwiceReverts() public {
        uint256 gameId = _openGame(0);
        vm.warp(block.timestamp + 24 hours + 1);
        dice.refund(gameId);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__NotRefundable.selector, gameId));
        dice.refund(gameId);
        assertEq(brb.balanceOf(alice), 1000 ether);
    }

    function test_RefundUnknownGameReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__NotRefundable.selector, 42));
        dice.refund(42);
    }

    function test_StuckCreatorVrf_Refund() public {
        vm.prank(alice);
        uint256 gameId = dice.throwCoin(BET);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(BraboDice.BraboDice__NotRefundable.selector, gameId));
        dice.refund(gameId);
        vm.warp(block.timestamp + 1);
        dice.refund(gameId);
        assertEq(brb.balanceOf(alice), 1000 ether);
        _fulfill(1, 0); // late answer must not reopen the game
        assertEq(dice.getOpenGames().length, 0);
        assertEq(uint8(dice.getGame(gameId).status), uint8(BraboDice.Status.Refunded));
    }

    function test_AcceptAtExactDeadline() public {
        uint256 gameId = _openGame(0);
        vm.warp(block.timestamp + 24 hours); // still inclusive
        vm.prank(bob);
        dice.acceptChallenge(gameId);
    }

    function test_InsufficientAllowanceReverts() public {
        address carol = makeAddr("carol");
        brb.mint(carol, BET);
        vm.prank(carol);
        vm.expectRevert();
        dice.throwCoin(BET);
    }

    function test_WithdrawNothingReverts() public {
        vm.expectRevert(BraboDice.BraboDice__NothingToWithdraw.selector);
        dice.withdraw();
    }

    function test_OnlyCoordinatorCanFulfill() public {
        _openGame(0);
        uint256[] memory words = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert();
        dice.rawFulfillRandomWords(1, words);
    }

    // ── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_WinnerRuleAndConservation(uint256 amount, uint256 w1, uint256 w2) public {
        amount = bound(amount, 1, 1000 ether);
        vm.prank(alice);
        uint256 gameId = dice.throwCoin(amount);
        _fulfill(1, w1);
        vm.prank(bob);
        dice.acceptChallenge(gameId);
        _fulfill(2, w2);

        bool creatorWins = (w1 % 2) == (w2 % 2);
        assertEq(brb.balanceOf(alice), creatorWins ? 1000 ether + amount : 1000 ether - amount);
        assertEq(brb.balanceOf(bob), creatorWins ? 1000 ether - amount : 1000 ether + amount);
        assertEq(brb.balanceOf(address(dice)), 0);
    }
}
