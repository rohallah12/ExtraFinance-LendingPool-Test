// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";

/**
 * @title Extra finance lending pool test suit
 * @author @rsam_eth
 * @notice Full test suit if extra finance lending pool 
 */
contract LendingTest is Test {
    LendingPool public lendingPool;

    function setUp() public {
        // lendingPool = new LendingPool();
    }
}
