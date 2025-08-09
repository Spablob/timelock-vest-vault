// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../contracts/CustodialVault.sol";

contract DeployCustodialVault is Script {
    // Deployment parameters

    address public constant FOUNDATION = address(0x623Cb5A594dAD5cc1Ea1bDb0b084bf8F1fE4B2e4); // Replace with actual foundation address
    address public constant LENDER = address(0x4a311575D3dD3e4c70A7C8A3B4C2056e26427Dbf); // Replace with actual lender address
    
    // IP token price feed ID on Story chain (now hardcoded in CustodialVault contract)
    // bytes32: 0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025
    
    // Initial price in 18 decimals (e.g., $1.00 = 1e18)
    uint256 public constant INITIAL_PRICE = 1e18; // $1.00
    
    // Total token amount expected in the vault
    uint256 public constant TOTAL_TOKEN_AMOUNT = 1000000 ether; // 1M IP tokens
    
    // Lock duration in seconds (8 months = ~243 days)
    uint256 public constant LOCK_DURATION = 243 days;

    function run() external {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("STORY_PRIVATEKEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        // Calculate lock end time
        uint256 lockEndTime = block.timestamp + LOCK_DURATION;
        
        // Deploy CustodialVault
        CustodialVault vault = new CustodialVault(
            FOUNDATION,
            LENDER,
            INITIAL_PRICE,
            TOTAL_TOKEN_AMOUNT,
            lockEndTime
        );
        
        // Log deployment information
        console.log("CustodialVault deployed at:", address(vault));
        console.log("Foundation:", FOUNDATION);
        console.log("Lender:", LENDER);
        console.log("Initial Price:", INITIAL_PRICE);
        console.log("Total Token Amount:", TOTAL_TOKEN_AMOUNT);
        console.log("Lock End Time:", lockEndTime);
        console.log("Lock End Date:", _timestampToString(lockEndTime));
        
        vm.stopBroadcast();
        
        // Post-deployment verification
        console.log("\n=== Deployment Verification ===");
        console.log("Pyth Oracle Address:", address(vault.PYTH_ORACLE()));
        console.log("Price Drop Threshold:", vault.PRICE_DROP_THRESHOLD(), "basis points");
        console.log("TWAP Window:", vault.TWAP_WINDOW() / 1 hours, "hours");
        console.log("Max Price Age:", vault.MAX_PRICE_AGE() / 1 minutes, "minutes");
        console.log("Price Freshness Window:", vault.PRICE_FRESHNESS_WINDOW() / 1 minutes, "minutes");
        
        // Write deployment info to file
        _writeDeploymentInfo(address(vault), lockEndTime);
    }
    
    function _timestampToString(uint256 timestamp) internal view returns (string memory) {
        // Simple date approximation for logging
        uint256 daysFromNow = (timestamp - block.timestamp) / 1 days;
        return string(abi.encodePacked("~", vm.toString(daysFromNow), " days from now"));
    }
    
    function _writeDeploymentInfo(address vaultAddress, uint256 lockEndTime) internal {
        // Build JSON in smaller parts to avoid stack too deep
        string memory part1 = string(abi.encodePacked(
            "{\n",
            '  "vault": "', vm.toString(vaultAddress), '",\n',
            '  "foundation": "', vm.toString(FOUNDATION), '",\n'
        ));
        
        string memory part2 = string(abi.encodePacked(
            '  "lender": "', vm.toString(LENDER), '",\n',
            '  "initialPrice": "', vm.toString(INITIAL_PRICE), '",\n'
        ));
        
        string memory part3 = string(abi.encodePacked(
            '  "totalTokenAmount": "', vm.toString(TOTAL_TOKEN_AMOUNT), '",\n',
            '  "lockEndTime": ', vm.toString(lockEndTime), ',\n'
        ));
        
        string memory part4 = string(abi.encodePacked(
            '  "deploymentBlock": ', vm.toString(block.number), ',\n',
            '  "deploymentTimestamp": ', vm.toString(block.timestamp), '\n',
            "}\n"
        ));
        
        string memory deploymentInfo = string(abi.encodePacked(part1, part2, part3, part4));
        
        vm.writeFile("deployments/custodial-vault-latest.json", deploymentInfo);
        console.log("\nDeployment info written to: deployments/custodial-vault-latest.json");
    }
}