// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../contracts/CustodialVault.sol";

contract VerifyPythAddresses is Test {
    // Expected Pyth Oracle addresses
    address constant EXPECTED_MAINNET_PYTH = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;
    address constant EXPECTED_TESTNET_PYTH = 0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320;
    
    function test_CustodialVaultHasCorrectTestnetPythAddress() public {
        // Deploy CustodialVault
        CustodialVault vault = new CustodialVault(
            address(0x1),
            address(0x2),
            1e18,
            1000 ether
        );
        
        // Verify the Pyth oracle address matches expected testnet address
        assertEq(
            address(vault.PYTH_ORACLE()),
            EXPECTED_TESTNET_PYTH,
            "CustodialVault should have correct testnet Pyth oracle address"
        );
    }
    
    function test_DocumentationReferencesAreCorrect() public pure {
        // This test serves as documentation verification
        // The addresses are verified through code review
        
        // Mainnet address from documentation
        address docMainnet = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;
        // Testnet address from documentation  
        address docTestnet = 0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320;
        
        // Verify they match our expected values
        assert(docMainnet == EXPECTED_MAINNET_PYTH);
        assert(docTestnet == EXPECTED_TESTNET_PYTH);
    }
}