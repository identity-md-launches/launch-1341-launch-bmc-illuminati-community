// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title BMC Illuminati (BMC)
/// @notice The launch token: a plain, fixed-supply ERC-20.
/// @dev 1,000,000,000 BMC with 18 decimals, minted once to the deployer (the launch factory), which
/// splits it: 10% to the swarm's MerkleDistributor, 88% into the Uniswap v4 pool, 2% to the launcher.
///
/// There is no owner, no mint, no pause, no blocklist, no transfer fee and no upgrade path. The only
/// way supply ever changes is `burn` / `burnFrom` (OpenZeppelin ERC20Burnable), which a holder can
/// use on its own balance only. The BMC hook uses `burn` to destroy the 1% of every sale it collects,
/// so `totalSupply()` is always the circulating supply after burns.
contract BMCToken is ERC20, ERC20Burnable {
    /// @notice The whole supply, minted once.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("BMC Illuminati", "BMC") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
