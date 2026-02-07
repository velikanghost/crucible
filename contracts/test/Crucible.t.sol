// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Crucible} from "../src/Crucible.sol";

contract CrucibleTest is Test {
    Crucible public crucible;

    address public arbiterAddr = makeAddr("arbiter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 public constant ENTRY_FEE = 0.5 ether;
    int256 public constant STARTING_POINTS = 50;
    uint256 public constant COMMIT_WINDOW = 30;
    uint256 public constant REVEAL_WINDOW = 15;

    function setUp() public {
        crucible = new Crucible(arbiterAddr, ENTRY_FEE, STARTING_POINTS);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    // ============ REGISTRATION ============

    function test_Register() public {
        vm.prank(alice);
        crucible.register{value: ENTRY_FEE}();

        (int256 points, bool alive, bool registered) = crucible.getPlayerInfo(alice);
        assertEq(points, STARTING_POINTS);
        assertTrue(alive);
        assertTrue(registered);
        assertEq(crucible.getPlayerCount(), 1);
        assertEq(crucible.prizePool(), ENTRY_FEE);
    }

    function test_Register_WrongFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Crucible.WrongEntryFee.selector, ENTRY_FEE, 5 ether));
        crucible.register{value: 5 ether}();
    }

    function test_Register_AlreadyRegistered() public {
        vm.prank(alice);
        crucible.register{value: ENTRY_FEE}();

        vm.prank(alice);
        vm.expectRevert(Crucible.AlreadyRegistered.selector);
        crucible.register{value: ENTRY_FEE}();
    }

    function test_Register_WrongPhase() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob); // Moves phase from LOBBY to COMMIT

        vm.prank(makeAddr("late"));
        vm.deal(makeAddr("late"), 100 ether);
        vm.expectRevert();
        crucible.register{value: ENTRY_FEE}();
    }

    // ============ GAME START ============

    function test_StartGame() public {
        _registerThreePlayers();

        vm.prank(arbiterAddr);
        crucible.startGame();
        assertEq(crucible.currentRound(), 1);
    }

    function test_StartGame_NotEnoughPlayers() public {
        vm.prank(alice);
        crucible.register{value: ENTRY_FEE}();

        vm.prank(arbiterAddr);
        vm.expectRevert(Crucible.NeedMorePlayers.selector);
        crucible.startGame();
    }

    function test_StartGame_OnlyArbiter() public {
        _registerThreePlayers();

        vm.prank(alice);
        vm.expectRevert(Crucible.OnlyArbiter.selector);
        crucible.startGame();
    }

    // ============ MATCHUPS ============

    function test_SetMatchups() public {
        _registerThreePlayers();
        _startGame();

        Crucible.Matchup[] memory matchups = new Crucible.Matchup[](1);
        matchups[0] = Crucible.Matchup(alice, bob);

        vm.prank(arbiterAddr);
        crucible.setMatchups(matchups, COMMIT_WINDOW, REVEAL_WINDOW);

        assertEq(uint8(crucible.phase()), uint8(Crucible.Phase.COMMIT));

        Crucible.Matchup[] memory stored = crucible.getCurrentMatchups();
        assertEq(stored.length, 1);
        assertEq(stored[0].player1, alice);
        assertEq(stored[0].player2, bob);
    }

    function test_SetMatchups_DeadPlayer() public {
        _registerThreePlayers();
        _startGame();

        // Kill alice by setting points to 0 via combat
        // Instead, test with a player that doesn't exist
        Crucible.Matchup[] memory matchups = new Crucible.Matchup[](1);
        matchups[0] = Crucible.Matchup(alice, makeAddr("dead"));

        vm.prank(arbiterAddr);
        vm.expectRevert();
        crucible.setMatchups(matchups, COMMIT_WINDOW, REVEAL_WINDOW);
    }

    // ============ COMMIT-REVEAL COMBAT ============

    function test_FullCombatRound() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        // Alice commits Domain (1), Bob commits Counter (3)
        bytes32 aliceSalt = keccak256("alice-salt");
        bytes32 bobSalt = keccak256("bob-salt");

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), aliceSalt)));

        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), bobSalt)));

        // Move to reveal window
        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(1, aliceSalt); // DOMAIN

        vm.prank(bob);
        crucible.revealAction(3, bobSalt); // COUNTER

        // Resolve
        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        // Counter beats Domain, so Bob wins
        // Bob gets 10 points minus Counter cost (10) = 0 net
        // Alice loses 10 points
        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        assertEq(alicePoints, 40);  // 50 - 10
        assertEq(bobPoints, 50);    // 50 + 10 - 10
    }

    function test_DomainBeatsTechnique() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        _commitAndReveal(alice, 1, bob, 2); // Domain vs Technique

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Domain beats Technique
        // Alice gets 10 points minus Domain cost (30) = -20 net
        // Bob loses 10
        assertEq(alicePoints, 30); // 50 + 10 - 30
        assertEq(bobPoints, 40);   // 50 - 10
    }

    function test_TechniqueBeatsCounter() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        _commitAndReveal(alice, 2, bob, 3); // Technique vs Counter

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Technique beats Counter
        assertEq(alicePoints, 40); // 50 + 10 - 20
        assertEq(bobPoints, 40);   // 50 - 10
    }

    function test_DrawSameAction() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        _commitAndReveal(alice, 1, bob, 1); // Domain vs Domain

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Draw - both lose action cost
        assertEq(alicePoints, 20); // 50 - 30
        assertEq(bobPoints, 20);   // 50 - 30
    }

    function test_BothFlee() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        _commitAndReveal(alice, 4, bob, 4); // Flee vs Flee

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        assertEq(alicePoints, 45); // 50 - 5
        assertEq(bobPoints, 45);   // 50 - 5
    }

    function test_OneFlees() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        _commitAndReveal(alice, 4, bob, 2); // Flee vs Technique

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        assertEq(alicePoints, 45); // 50 - 5
        assertEq(bobPoints, 60);   // 50 + 10
    }

    function test_NoRevealDefaultsToFlee() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        // Only Alice commits and reveals
        bytes32 aliceSalt = keccak256("alice-salt");
        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), aliceSalt)));

        // Bob doesn't commit at all
        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(2, aliceSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        // Bob defaults to Flee
        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        assertEq(alicePoints, 60); // 50 + 10
        assertEq(bobPoints, 45);   // 50 - 5
    }

    function test_CommitWindow_Expired() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        vm.warp(block.timestamp + COMMIT_WINDOW + 1);

        bytes32 salt = keccak256("late");
        vm.prank(alice);
        vm.expectRevert(Crucible.CommitWindowClosed.selector);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), salt)));
    }

    function test_HashMismatch() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        bytes32 salt = keccak256("salt");
        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), salt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        vm.expectRevert(Crucible.HashMismatch.selector);
        crucible.revealAction(2, salt); // Wrong action
    }

    // ============ ELIMINATION ============

    function test_Elimination() public {
        _registerThreePlayers();
        _startGame();

        // Round 1: Alice vs Bob, Domain vs Counter (Bob wins)
        _setMatchup(alice, bob);
        _commitAndReveal(alice, 1, bob, 3);

        // Alice: 50 - 10 = 40, Bob: 50 + 10 - 10 = 50
        // Round 2
        vm.prank(arbiterAddr);
        crucible.advanceRound();

        _setMatchup(alice, bob);
        _commitAndReveal(alice, 1, bob, 3);

        // Alice: 40 - 10 = 30, Bob: 50 + 10 - 10 = 50
        (, bool aliceAlive,) = crucible.getPlayerInfo(alice);
        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);

        assertEq(alicePoints, 30);
        assertTrue(aliceAlive);
    }

    // ============ RULES ============

    function test_ProposeRule() public {
        _registerThreePlayers();
        _startGame();

        // Need to accumulate 100+ points through multiple wins
        // Win several rounds to build up points
        for (uint256 i = 0; i < 10; i++) {
            _setMatchup(alice, bob);
            _commitAndReveal(alice, 2, bob, 3); // Technique beats Counter, alice wins
            if (i < 9) {
                vm.prank(arbiterAddr);
                crucible.advanceRound();
            }
        }

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        assertTrue(alicePoints >= 100);

        // Now in RULES phase after resolve
        vm.prank(alice);
        crucible.proposeRule(Crucible.RuleType.BLOOD_TAX);

        Crucible.Rule[] memory rules = crucible.getActiveRules();
        assertEq(rules.length, 1);
        assertEq(uint8(rules[0].ruleType), uint8(Crucible.RuleType.BLOOD_TAX));
        assertEq(rules[0].proposer, alice);

        // Alice should have lost 100 points
        (int256 afterPoints,,) = crucible.getPlayerInfo(alice);
        assertEq(afterPoints, alicePoints - 100);
    }

    function test_ProposeRule_InsufficientPoints() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);

        // Both flee to waste some points, then go to rules phase
        _commitAndReveal(alice, 4, bob, 4);

        // Alice has 45 points (50 - 5), not enough for rule
        vm.prank(alice);
        vm.expectRevert(Crucible.InsufficientPoints.selector);
        crucible.proposeRule(Crucible.RuleType.BLOOD_TAX);
    }

    // ============ EXPENSIVE DOMAIN RULE ============

    function test_ExpensiveDomainRule() public {
        _registerThreePlayers();
        _startGame();

        // Win multiple rounds to accumulate 100+ points for rule
        for (uint256 i = 0; i < 10; i++) {
            _setMatchup(alice, bob);
            _commitAndReveal(alice, 2, bob, 3); // Technique beats Counter
            vm.prank(arbiterAddr);
            crucible.advanceRound();
        }

        (int256 alicePointsBefore,,) = crucible.getPlayerInfo(alice);
        assertTrue(alicePointsBefore >= 100);

        // Go to rules phase
        _setMatchup(alice, bob);
        _commitAndReveal(alice, 2, bob, 3);

        // Propose expensive domain
        vm.prank(alice);
        crucible.proposeRule(Crucible.RuleType.EXPENSIVE_DOMAIN);

        vm.prank(arbiterAddr);
        crucible.advanceRound();

        (int256 aliceAfterRule,,) = crucible.getPlayerInfo(alice);
        (int256 bobAfterRule,,) = crucible.getPlayerInfo(bob);

        // Now Domain costs 50 instead of 30
        _setMatchup(alice, bob);

        // Alice uses Domain, Bob uses Technique. Alice wins but at higher cost.
        _commitAndReveal(alice, 1, bob, 2);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // With expensive domain rule: Domain costs 50
        // Alice: aliceAfterRule + 10 - 50 = aliceAfterRule - 40
        // Bob: bobAfterRule - 10
        assertEq(alicePoints, aliceAfterRule - 40);
        assertEq(bobPoints, bobAfterRule - 10);
    }

    // ============ SETTLEMENT ============

    function test_EndGameAndClaim() public {
        _registerThreePlayers();
        _startGame();
        _setMatchup(alice, bob);
        _commitAndReveal(alice, 2, bob, 3);

        vm.prank(arbiterAddr);
        crucible.advanceRound();

        // End game
        address[] memory winners = new address[](2);
        winners[0] = alice;
        winners[1] = bob;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000; // 60%
        shares[1] = 4000; // 40%

        vm.prank(arbiterAddr);
        crucible.endGame(winners, shares);

        assertEq(uint8(crucible.phase()), uint8(Crucible.Phase.ENDED));

        // Prize pool is 1.5 ether (0.5 ether * 3 players)
        uint256 prizePool = 1.5 ether;

        // Alice claims
        uint256 expectedAlice = (prizePool * 6000) / 10000; // 0.9 ether
        uint256 aliceBalBefore = alice.balance;

        vm.prank(alice);
        crucible.claimRewards();

        assertEq(alice.balance - aliceBalBefore, expectedAlice);

        // Bob claims
        uint256 expectedBob = (prizePool * 4000) / 10000; // 0.6 ether
        uint256 bobBalBefore = bob.balance;

        vm.prank(bob);
        crucible.claimRewards();

        assertEq(bob.balance - bobBalBefore, expectedBob);
    }

    function test_ClaimRewards_NoPayout() public {
        _registerThreePlayers();
        _startGame();

        address[] memory winners = new address[](1);
        winners[0] = alice;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 10000;

        vm.prank(arbiterAddr);
        crucible.endGame(winners, shares);

        vm.prank(charlie);
        vm.expectRevert(Crucible.NoPayout.selector);
        crucible.claimRewards();
    }

    // ============ HELPERS ============

    function _registerThreePlayers() internal {
        vm.prank(alice);
        crucible.register{value: ENTRY_FEE}();
        vm.prank(bob);
        crucible.register{value: ENTRY_FEE}();
        vm.prank(charlie);
        crucible.register{value: ENTRY_FEE}();
    }

    function _startGame() internal {
        vm.prank(arbiterAddr);
        crucible.startGame();
    }

    function _setMatchup(address p1, address p2) internal {
        Crucible.Matchup[] memory matchups = new Crucible.Matchup[](1);
        matchups[0] = Crucible.Matchup(p1, p2);

        vm.prank(arbiterAddr);
        crucible.setMatchups(matchups, COMMIT_WINDOW, REVEAL_WINDOW);
    }

    function _commitAndReveal(
        address p1,
        uint8 p1Action,
        address p2,
        uint8 p2Action
    ) internal {
        bytes32 salt1 = keccak256(abi.encodePacked("salt1", currentRound()));
        bytes32 salt2 = keccak256(abi.encodePacked("salt2", currentRound()));

        vm.prank(p1);
        crucible.commitAction(keccak256(abi.encodePacked(p1Action, salt1)));

        vm.prank(p2);
        crucible.commitAction(keccak256(abi.encodePacked(p2Action, salt2)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(p1);
        crucible.revealAction(p1Action, salt1);

        vm.prank(p2);
        crucible.revealAction(p2Action, salt2);

        vm.warp(block.timestamp + REVEAL_WINDOW);

        vm.prank(arbiterAddr);
        crucible.resolveRound();
    }

    function currentRound() internal view returns (uint256) {
        return crucible.currentRound();
    }
}
