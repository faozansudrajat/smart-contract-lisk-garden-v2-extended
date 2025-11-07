// GardenToken.sol (VERSI MODIFIKASI FINAL UNTUK DEPLOYMENT)
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract GardenToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Constructor TIDAK lagi membutuhkan alamat LiskGardenV2
    constructor() ERC20("Garden Token", "GDN") {
        // Memberikan DEFAULT_ADMIN_ROLE kepada deployer (Anda)
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    // FUNGSI BARU: Untuk memberikan role kepada LiskGardenV2 setelah deployment
    function grantMinterAndBurnerRole(address contractAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, contractAddress);
        _grantRole(BURNER_ROLE, contractAddress);
    }
    
    // (Fungsi mint dan burn tetap sama)
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
    
    function burn(uint256 amount) public onlyRole(BURNER_ROLE) {
        _burn(msg.sender, amount);
    }
}
