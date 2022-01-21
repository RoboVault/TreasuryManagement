// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import './helpers.sol';

struct strategyParamaters {
    address underlyingAsset;    // underlyingasset for strategy
    uint256 allocation;         // multiplier determing how much of underlying allocated to strategy
    address deployAddress;      // address where unerlying asset is deployed 
    bool useVault;              // True if strategy is an auto-compounding vault 
    bool useFarm;               // True if strategy is a Yield Farm
    uint256 farmType;           // index for type of farm 
    uint256 pid;                // Pool ID (for farms)
}

/*
farmType
0 = standard masterchef i.e. SpookyFarm
1 = gauge i.e. Spirit Farm
2 = LQDR farm
3 = Beets farm  
*/


contract treasury is helpers {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 public minZapBalance; 

    mapping(address => uint256[]) strategyIDs; 
    mapping(address => uint256) totalAllocations;
    mapping(uint256 => strategyParamaters) strategies;
    mapping(address => uint256) totalBonded; 

    address[] public assets;
    IERC20 public wftm;
    uint256 public lpAllocaiton; 

    uint256 strategyCounter;
    uint256 timePerEpoch;


    constructor (address _wftm) public {
        wftm = IERC20(_wftm);
    } 

    function migrateToNewTreasury(address _newTreasury) external onlyOwner {
        _undeployAssets();

        for (uint256 i = 0; i < assets.length; i++){
            IERC20 transferToken = IERC20(assets[i]);
            transferToken.transfer(_newTreasury, transferToken.balanceOf(address(this)));
        }        

    }

    function addAsset(address _asset) external onlyAuthorized { 
        assets.push(_asset);
    }

    function calcTotalBalance(address _underlying) public view returns(uint256) {
        IERC20 underlying = IERC20(_underlying);
        uint256[] storage underlyingAllocationIds = strategyIDs[_underlying];
        uint256 balance;
        for (uint256 i = 0; i < underlyingAllocationIds.length; i++){
            uint256 strategyId = underlyingAllocationIds[i];
            strategyParamaters storage strat = strategies[strategyId];
            balance = balance + getBalanceDeployed(strat.deployAddress, strat.useVault, strat.pid);
        }
        return(balance);
    }

    function calcProfit(address _underlying) public view returns(uint256) {
        uint256 profit = calcTotalBalance(_underlying).sub(totalBonded[_underlying]);
        return(profit);
    }

    function calcAssetBalance(address _underlying) public view returns(uint256) {
        IERC20 underlying = IERC20(_underlying);
        uint256 bal = underlying.balanceOf(address(this));
        uint256[] storage underlyingAllocationIds = strategyIDs[_underlying];       
        for (uint256 i = 0; i < underlyingAllocationIds.length; i++){
            uint256 strategyId = underlyingAllocationIds[i];
            strategyParamaters storage strat = strategies[strategyId];
            bal = bal + _calcBalanceInStrat(strat);
        }
        return(bal);
    }


    function _calcBalanceInStrat(strategyParamaters storage strat) internal view returns(uint256){
        uint256 bal;
        if(strat.useFarm){
            bal = bal + farmBalance(strat.deployAddress, strat.pid);
        }

        if(strat.useVault){
            bal = bal + vaultBalance(strat.deployAddress);
        }
        return(bal);
    }


    function addFarm(address _underlying, uint256 _allocation, address _farmAddress, uint256 _farmType, uint256 _pid) external onlyAuthorized {
        _recordFarmDetails(_underlying, _allocation, _farmAddress, _farmType, _pid);
        _updateAllocationInformation(_underlying, _allocation);
        _approveNewEarner(_underlying, _farmAddress);

    }

    function addVault(address _underlying, uint256 _allocation, address _vaultAddress) external onlyAuthorized {
        _recordVaultDetails(_underlying, _allocation, _vaultAddress);
        _updateAllocationInformation(_underlying, _allocation);
        _approveNewEarner(_underlying, _vaultAddress);
    }

    function removeStrategy(uint256 _strategyID) external onlyAuthorized {
        strategyParamaters storage strat = strategies[_strategyID];
        address underlying = strat.underlyingAsset;
        uint256[] storage underlyingAllocationIds = strategyIDs[underlying];

        uint256 allocationIndex;
        for (uint256 i = 0; i < underlyingAllocationIds.length; i++){
            if (_strategyID == underlyingAllocationIds[i]){
                allocationIndex = i;
            }
        } 

        uint256 i = allocationIndex;
        while(i < underlyingAllocationIds.length - 1) {
            underlyingAllocationIds[i] = underlyingAllocationIds[i + 1];
            i++;
        }

        delete underlyingAllocationIds[underlyingAllocationIds.length - 1];
        underlyingAllocationIds.pop();
        strategyIDs[underlying] = underlyingAllocationIds;

        _unlockUnderlying(strat.deployAddress, strat.useVault, strat.useFarm, strat.farmType ,strat.pid);
        _removeApprovals(underlying, strat.deployAddress);

    }


    function _recordFarmDetails(address _underlying, uint256 _allocation, address _farmAddress, uint256 _farmType ,uint256 _pid) internal {
        bool useVault = false;
        bool useFarm = true;
        strategyParamaters memory newStrategy = strategyParamaters(_underlying, _allocation, _farmAddress, useVault, useFarm, _farmType , _pid);
        strategies[strategyCounter] = newStrategy;

    }


    function _recordVaultDetails(address _underlying, uint256 _allocation, address _vaultAddress) internal {
        bool useVault = true;
        bool useFarm = false;

        strategyParamaters memory newStrategy = strategyParamaters(_underlying, _allocation, _vaultAddress, useVault, useFarm, 0 ,0);
        strategies[strategyCounter] = newStrategy;

    }

    function _updateAllocationInformation(address _underlying, uint256 _allocation) internal {
        uint256 underlyingallocation = totalAllocations[_underlying];
        totalAllocations[_underlying] = underlyingallocation + _allocation;
        
        uint256[] storage underlyingAllocationIds = strategyIDs[_underlying];
        underlyingAllocationIds.push(strategyCounter);
        strategyIDs[_underlying] = underlyingAllocationIds;
        strategyCounter = strategyCounter+1;
    }

    /// deploys LP's & assets held in treasury to allocated farms / vaults
    function deployAssets() external onlyAuthorized {

        for (uint256 i = 0; i < assets.length; i++){
            address asset = assets[i];
            _deployAsset(asset);
        }

    }

    // deploys balance of asset according to allocation weights 
    function _deployAsset(address _underlying) internal {
        // denominator for deciding how to spread balance 
        uint256 allocationTotal = totalAllocations[_underlying];
        IERC20 underlying = IERC20(_underlying);
        uint256[] storage underlyingAllocationIds = strategyIDs[_underlying];
        uint256 balance = underlying.balanceOf(address(this));
        
        for (uint256 i = 0; i < underlyingAllocationIds.length; i++){
            uint256 strategyId = underlyingAllocationIds[i];
            strategyParamaters storage strat = strategies[strategyId];
            uint256 _deployAmt = balance.mul(strat.allocation).div(allocationTotal);
            _depositAsset(strat.deployAddress, strat.useVault, strat.useFarm,strat.farmType, strat.pid, _deployAmt );
        }
    }

    function harvestRewards() external onlyAuthorized {
        for (uint256 i = 0; i < strategyCounter; i++){
            strategyParamaters storage strat = strategies[i];
            if (strat.useFarm){
                _harvestFarm(strat.deployAddress, strat.farmType, strat.pid);
            }
        }

    }

    /// deploys LP's & assets held in treasury to allocated farms / vaults
    function undeployAssets() external onlyAuthorized {
        _undeployAssets();
    }

    function _undeployAssets() internal {

        for (uint256 i = 0; i < assets.length; i++){
            address asset = assets[i];
            _undeployAsset(asset);
        }

    }

    // undeploys asset from allocated vaults / farms 
    function _undeployAsset(address _underlying) internal {
        IERC20 underlying = IERC20(_underlying);
        uint256[] storage underlyingAllocationIds = strategyIDs[_underlying];
        
        for (uint256 i = 0; i < underlyingAllocationIds.length; i++){
            uint256 strategyId = underlyingAllocationIds[i];
            strategyParamaters storage strat = strategies[strategyId];
            _unlockUnderlying(strat.deployAddress, strat.useVault, strat.useFarm, strat.farmType ,strat.pid);
        }
    }

}

