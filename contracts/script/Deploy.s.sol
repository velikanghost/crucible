// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/Crucible.sol";

contract Deploy is Script {
    struct NetworkConfig {
        string networkName;
        string nativeToken;
        bool isTestnet;
    }

    function setUp() public {}

    function getDeploymentConfig()
        internal
        pure
        returns (NetworkConfig memory config)
    {
        config = NetworkConfig({
            networkName: "Monad Testnet",
            nativeToken: "MON",
            isTestnet: true
        });
    }

    function run() external {
        NetworkConfig memory config = getDeploymentConfig();

        address arbiterAddress = vm.envAddress("ARBITER_ADDRESS");
        uint256 entryFee = vm.envOr("ENTRY_FEE", uint256(0.5 ether));
        int256 startingPoints = vm.envOr("STARTING_POINTS", int256(50));

        console2.log("Arbiter:", arbiterAddress);
        console2.log("Entry Fee:", entryFee);
        console2.log("Starting Points:", startingPoints);

        vm.startBroadcast(arbiterAddress);

        // Deploy Crucible contract
        console2.log("\nDeploying Crucible...");

        Crucible crucible = new Crucible(
            arbiterAddress,
            entryFee,
            startingPoints
        );
        console2.log("Crucible deployed at:", address(crucible));

        vm.stopBroadcast();

        logDeployment(address(crucible), arbiterAddress, config);
    }

    function logDeployment(
        address crucible,
        address deployer,
        NetworkConfig memory config
    ) internal pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("Network:", config.networkName);
        console2.log("Native Token:", config.nativeToken);
        console2.log("\n--- Contract Address ---");
        console2.log("Crucible:", crucible);
        console2.log("\n--- Configuration ---");
        console2.log("Admin:", deployer);
        console2.log("\n=== Deployment Complete ===");
    }
}
