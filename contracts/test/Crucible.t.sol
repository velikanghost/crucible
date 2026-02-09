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
    int256 public constant STARTING_POINTS = 200;
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
        _startRound();

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
        assertGt(crucible.currentRound(), 0);
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

    // ============ START ROUND ============

    function test_StartRound() public {
        _registerThreePlayers();
        _startGame();

        vm.prank(arbiterAddr);
        crucible.startRound(COMMIT_WINDOW, REVEAL_WINDOW);

        assertEq(uint8(crucible.phase()), uint8(Crucible.Phase.COMMIT));
    }

    // ============ MUTUAL COMBAT (both target each other) ============

    function test_MutualCombat_CounterBeatsDomain() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        // Alice: Domain(bob), Bob: Counter(alice) — mutual combat, Bob wins
        _commitAndRevealMutual(alice, 1, bob, bob, 3, alice);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Mutual combat transfer = 15
        // Bob wins: Bob gets +15 - 10(counter cost) = +5, Alice gets -15
        assertEq(alicePoints, 185);  // 200 - 15
        assertEq(bobPoints, 205);    // 200 + 15 - 10
    }

    function test_MutualCombat_DomainBeatsTechnique() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        _commitAndRevealMutual(alice, 1, bob, bob, 2, alice);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Alice wins: Alice gets +15 - 30 = -15, Bob gets -15
        assertEq(alicePoints, 185);  // 200 + 15 - 30
        assertEq(bobPoints, 185);    // 200 - 15
    }

    function test_MutualCombat_TechniqueBeatsCounter() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        _commitAndRevealMutual(alice, 2, bob, bob, 3, alice);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Alice wins: +15 - 20 = -5 net. Bob: -15
        assertEq(alicePoints, 195);  // 200 + 15 - 20
        assertEq(bobPoints, 185);    // 200 - 15
    }

    function test_MutualCombat_Draw() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        _commitAndRevealMutual(alice, 1, bob, bob, 1, alice);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Draw: both pay action cost (Domain = 30)
        assertEq(alicePoints, 170);  // 200 - 30
        assertEq(bobPoints, 170);    // 200 - 30
    }

    function test_MutualCombat_BothFlee() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        _commitAndRevealFlee(alice, bob);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        assertEq(alicePoints, 195);  // 200 - 5
        assertEq(bobPoints, 195);    // 200 - 5
    }

    function test_MutualCombat_OneFleesOneAttacks() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        // Alice flees (no target), Bob attacks Alice — one-way from Bob
        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(4), address(0), aliceSalt)));

        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), alice, bobSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(4, address(0), aliceSalt);

        vm.prank(bob);
        crucible.revealAction(2, alice, bobSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Alice fled: pays 5. Gets hit by Bob one-way: damage = 5 (halved because fled)
        // Bob: pays technique cost (20)
        assertEq(alicePoints, 190);  // 200 - 5 - 5
        assertEq(bobPoints, 180);    // 200 - 20
    }

    // ============ ONE-WAY ATTACKS ============

    function test_OneWayAttack() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        // Circular: Alice→Bob, Bob→Charlie, Charlie→Alice (all one-way)
        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));
        bytes32 charlieSalt = keccak256(abi.encodePacked("salt-charlie", crucible.currentRound()));

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), bob, aliceSalt)));
        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), charlie, bobSalt)));
        vm.prank(charlie);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), alice, charlieSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(2, bob, aliceSalt);
        vm.prank(bob);
        crucible.revealAction(3, charlie, bobSalt);
        vm.prank(charlie);
        crucible.revealAction(1, alice, charlieSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);
        (int256 charliePoints,,) = crucible.getPlayerInfo(charlie);

        // All one-way (A→B→C→A circular):
        // Alice→Bob: pays 20, Bob takes 10
        // Bob→Charlie: pays 10, Charlie takes 10
        // Charlie→Alice: pays 30, Alice takes 10
        assertEq(alicePoints, 170);   // 200 - 20 - 10
        assertEq(bobPoints, 180);     // 200 - 10 - 10
        assertEq(charliePoints, 160); // 200 - 30 - 10
    }

    function test_MultipleAttackersOnSameTarget() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        // Alice(Counter)→Bob, Bob(Technique)→Charlie, Charlie(Domain)→Bob
        // Bob targets Charlie, Charlie targets Bob → mutual combat!
        // Alice→Bob is one-way
        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));
        bytes32 charlieSalt = keccak256(abi.encodePacked("salt-charlie", crucible.currentRound()));

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), bob, aliceSalt)));
        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), charlie, bobSalt)));
        vm.prank(charlie);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), bob, charlieSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(3, bob, aliceSalt);
        vm.prank(bob);
        crucible.revealAction(2, charlie, bobSalt);
        vm.prank(charlie);
        crucible.revealAction(1, bob, charlieSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);
        (int256 charliePoints,,) = crucible.getPlayerInfo(charlie);

        // Alice→Bob: one-way. Alice pays 10(counter), Bob takes 10.
        // Bob↔Charlie: mutual. Bob(Technique) vs Charlie(Domain). Domain beats Technique → Charlie wins.
        //   Charlie: +15 - 30 = -15 → 200 - 15 = 185
        //   Bob: -15
        // Bob total: 200 - 10(from alice) - 15(mutual loss) = 175
        assertEq(alicePoints, 190);   // 200 - 10
        assertEq(bobPoints, 175);     // 200 - 10 - 15
        assertEq(charliePoints, 185); // 200 + 15 - 30
    }

    // ============ FLEE MECHANICS ============

    function test_FleeReducesOneWayDamage() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), bob, aliceSalt)));
        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(4), address(0), bobSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(2, bob, aliceSalt);
        vm.prank(bob);
        crucible.revealAction(4, address(0), bobSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Alice: pays 20. Bob: pays 5(flee), takes 5(halved damage)
        assertEq(alicePoints, 180);  // 200 - 20
        assertEq(bobPoints, 190);    // 200 - 5 - 5
    }

    // ============ NO REVEAL DEFAULTS TO FLEE ============

    function test_NoRevealDefaultsToFlee() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));

        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), bob, aliceSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);
        vm.prank(alice);
        crucible.revealAction(2, bob, aliceSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Bob defaults to FLEE. Alice→Bob one-way, halved damage.
        assertEq(alicePoints, 180);  // 200 - 20
        assertEq(bobPoints, 190);    // 200 - 5 - 5
    }

    // ============ COMMIT WINDOW ============

    function test_CommitWindow_Expired() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        vm.warp(block.timestamp + COMMIT_WINDOW + 1);

        bytes32 salt = keccak256("late");
        vm.prank(alice);
        vm.expectRevert(Crucible.CommitWindowClosed.selector);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), bob, salt)));
    }

    function test_HashMismatch() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        bytes32 salt = keccak256("salt");
        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), bob, salt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        vm.expectRevert(Crucible.HashMismatch.selector);
        crucible.revealAction(2, bob, salt);
    }

    // ============ ELIMINATION ============

    function test_Elimination() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));
        bytes32 charlieSalt = keccak256(abi.encodePacked("salt-charlie", crucible.currentRound()));

        // Alice(Domain→Bob), Bob(Counter→Alice) mutual, Charlie(Counter→Alice) one-way
        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), bob, aliceSalt)));
        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), alice, bobSalt)));
        vm.prank(charlie);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), alice, charlieSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(1, bob, aliceSalt);
        vm.prank(bob);
        crucible.revealAction(3, alice, bobSalt);
        vm.prank(charlie);
        crucible.revealAction(3, alice, charlieSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints, bool aliceAlive,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);
        (int256 charliePoints,,) = crucible.getPlayerInfo(charlie);

        // Mutual: Alice(Domain) vs Bob(Counter) — Bob wins. Alice -15, Bob +15-10=+5
        // One-way: Charlie(Counter)→Alice. Charlie -10(cost), Alice -10(damage)
        assertEq(alicePoints, 175);   // 200 - 15 - 10
        assertEq(bobPoints, 205);     // 200 + 15 - 10
        assertEq(charliePoints, 190); // 200 - 10
        assertTrue(aliceAlive);
    }

    // ============ RULES ============

    function test_ProposeRule() public {
        _registerThreePlayers();
        _startGame();

        // Win rounds: Alice(Counter) beats Bob(Domain) = +5/round for Alice
        for (uint256 i = 0; i < 8; i++) {
            _startRound();
            _commitAndRevealMutual(alice, 3, bob, bob, 1, alice);
            vm.prank(arbiterAddr);
            crucible.advanceRound();
        }

        // Alice: 200 + 8*5 = 240. Bob: 200 - 8*15 = 80.
        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        assertTrue(alicePoints >= 100);

        _startRound();
        _commitAndRevealMutual(alice, 3, bob, bob, 1, alice);

        vm.prank(alice);
        crucible.proposeRule(Crucible.RuleType.BLOOD_TAX);

        Crucible.Rule[] memory rules = crucible.getActiveRules();
        assertEq(rules.length, 1);
        assertEq(uint8(rules[0].ruleType), uint8(Crucible.RuleType.BLOOD_TAX));
        assertEq(rules[0].proposer, alice);

        (int256 afterPoints,,) = crucible.getPlayerInfo(alice);
        assertEq(afterPoints, alicePoints + 5 - 100); // gained 5 from round, lost 100 from rule
    }

    function test_ProposeRule_InsufficientPoints() public {
        _registerThreePlayers();
        _startGame();

        // Burn points: 4 rounds of Domain draw (cost 30 each) → 200 - 120 = 80
        for (uint256 i = 0; i < 4; i++) {
            _startRound();
            _commitAndRevealMutual(alice, 1, bob, bob, 1, alice);
            if (i < 3) {
                vm.prank(arbiterAddr);
                crucible.advanceRound();
            }
        }

        // Alice has 80 points, not enough for rule (requires 100)
        vm.prank(alice);
        vm.expectRevert(Crucible.InsufficientPoints.selector);
        crucible.proposeRule(Crucible.RuleType.BLOOD_TAX);
    }

    // ============ EXPENSIVE DOMAIN RULE ============

    function test_ExpensiveDomainRule() public {
        _registerThreePlayers();
        _startGame();

        for (uint256 i = 0; i < 8; i++) {
            _startRound();
            _commitAndRevealMutual(alice, 3, bob, bob, 1, alice);
            vm.prank(arbiterAddr);
            crucible.advanceRound();
        }

        _startRound();
        _commitAndRevealMutual(alice, 3, bob, bob, 1, alice);

        vm.prank(alice);
        crucible.proposeRule(Crucible.RuleType.EXPENSIVE_DOMAIN);

        vm.prank(arbiterAddr);
        crucible.advanceRound();

        (int256 aliceAfterRule,,) = crucible.getPlayerInfo(alice);
        (int256 bobAfterRule,,) = crucible.getPlayerInfo(bob);

        // Now Domain costs 50 instead of 30
        _startRound();
        _commitAndRevealMutual(alice, 1, bob, bob, 2, alice);

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);

        // Alice(Domain) beats Bob(Technique) — mutual, transfer=15
        // Alice: +15 - 50(expensive domain) = -35
        // Bob: -15
        assertEq(alicePoints, aliceAfterRule - 35);
        assertEq(bobPoints, bobAfterRule - 15);
    }

    // ============ SETTLEMENT ============

    function test_EndGameAutoDistribute() public {
        _registerThreePlayers();
        _startGame();
        _startRound();
        _commitAndRevealMutual(alice, 2, bob, bob, 3, alice);

        vm.prank(arbiterAddr);
        crucible.advanceRound();

        address[] memory winners = new address[](2);
        winners[0] = alice;
        winners[1] = bob;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        uint256 pool = 1.5 ether;
        uint256 expectedAlice = (pool * 6000) / 10000;
        uint256 expectedBob = (pool * 4000) / 10000;

        uint256 aliceBalBefore = alice.balance;
        uint256 bobBalBefore = bob.balance;

        vm.prank(arbiterAddr);
        crucible.endGame(winners, shares);

        assertEq(uint8(crucible.phase()), uint8(Crucible.Phase.ENDED));
        assertEq(alice.balance - aliceBalBefore, expectedAlice);
        assertEq(bob.balance - bobBalBefore, expectedBob);
    }

    // ============ THREE PLAYER FREE-FOR-ALL ============

    function test_ThreePlayerFreeForAll() public {
        _registerThreePlayers();
        _startGame();
        _startRound();

        bytes32 aliceSalt = keccak256(abi.encodePacked("salt-alice", crucible.currentRound()));
        bytes32 bobSalt = keccak256(abi.encodePacked("salt-bob", crucible.currentRound()));
        bytes32 charlieSalt = keccak256(abi.encodePacked("salt-charlie", crucible.currentRound()));

        // Alice(Domain)→Bob, Bob(Technique)→Alice: mutual. Domain beats Technique.
        // Charlie(Counter)→Bob: one-way.
        vm.prank(alice);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(1), bob, aliceSalt)));
        vm.prank(bob);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(2), alice, bobSalt)));
        vm.prank(charlie);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(3), bob, charlieSalt)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(alice);
        crucible.revealAction(1, bob, aliceSalt);
        vm.prank(bob);
        crucible.revealAction(2, alice, bobSalt);
        vm.prank(charlie);
        crucible.revealAction(3, bob, charlieSalt);

        vm.warp(block.timestamp + REVEAL_WINDOW);
        vm.prank(arbiterAddr);
        crucible.resolveRound();

        (int256 alicePoints,,) = crucible.getPlayerInfo(alice);
        (int256 bobPoints,,) = crucible.getPlayerInfo(bob);
        (int256 charliePoints,,) = crucible.getPlayerInfo(charlie);

        // Mutual: Alice(Domain) beats Bob(Technique) → Alice +15-30=-15, Bob -15
        // One-way: Charlie(Counter)→Bob → Charlie -10(cost), Bob -10(damage)
        assertEq(alicePoints, 185);   // 200 + 15 - 30
        assertEq(bobPoints, 175);     // 200 - 15 - 10
        assertEq(charliePoints, 190); // 200 - 10
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

    function _startRound() internal {
        vm.prank(arbiterAddr);
        crucible.startRound(COMMIT_WINDOW, REVEAL_WINDOW);
    }

    function _commitAndRevealMutual(
        address p1, uint8 p1Action, address t1,
        address p2, uint8 p2Action, address t2
    ) internal {
        bytes32 salt1 = keccak256(abi.encodePacked("salt1", crucible.currentRound()));
        bytes32 salt2 = keccak256(abi.encodePacked("salt2", crucible.currentRound()));

        vm.prank(p1);
        crucible.commitAction(keccak256(abi.encodePacked(p1Action, t1, salt1)));

        vm.prank(p2);
        crucible.commitAction(keccak256(abi.encodePacked(p2Action, t2, salt2)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(p1);
        crucible.revealAction(p1Action, t1, salt1);

        vm.prank(p2);
        crucible.revealAction(p2Action, t2, salt2);

        vm.warp(block.timestamp + REVEAL_WINDOW);

        vm.prank(arbiterAddr);
        crucible.resolveRound();
    }

    function _commitAndRevealFlee(address p1, address p2) internal {
        bytes32 salt1 = keccak256(abi.encodePacked("salt1", crucible.currentRound()));
        bytes32 salt2 = keccak256(abi.encodePacked("salt2", crucible.currentRound()));

        vm.prank(p1);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(4), address(0), salt1)));

        vm.prank(p2);
        crucible.commitAction(keccak256(abi.encodePacked(uint8(4), address(0), salt2)));

        vm.warp(block.timestamp + COMMIT_WINDOW);

        vm.prank(p1);
        crucible.revealAction(4, address(0), salt1);

        vm.prank(p2);
        crucible.revealAction(4, address(0), salt2);

        vm.warp(block.timestamp + REVEAL_WINDOW);

        vm.prank(arbiterAddr);
        crucible.resolveRound();
    }
}
