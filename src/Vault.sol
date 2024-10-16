// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

struct VaultCurator {
    address curator;
    uint256 depositAmount;
    uint256 fees;
}

contract Vault {
    address public lendingAsset;
}
