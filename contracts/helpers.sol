// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "../interfaces/vaults.sol";
import "../interfaces/farm.sol";
import "../interfaces/gauge.sol";
import "../interfaces/uniswap.sol";
import "../interfaces/balancerv2.sol";


import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


// Helpers for treasury management 
// Includes Permissions mgmt + helpers for tracking balance within treasury
abstract contract helpers is Ownable {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
 
    address public keeper;
    address public strategist; 

    // modifiers
    modifier onlyAuthorized() {
        require(
            msg.sender == strategist || msg.sender == owner(),
            "!authorized"
        );
        _;
    }

    modifier onlyStrategist() {
        require(msg.sender == strategist, "!strategist");
        _;
    }

    modifier onlyKeepers() {
        require(
            msg.sender == keeper ||
                msg.sender == strategist ||
                msg.sender == owner() ||
                !Address.isContract(msg.sender),
            "!authorized"
        );
        _;
    }

    function setStrategist(address _strategist) external onlyAuthorized {
        require(_strategist != address(0));
        strategist = _strategist;
    }

    function setKeeper(address _keeper) external onlyAuthorized {
        require(_keeper != address(0));
        keeper = _keeper;
    }

    // deposits underlying asset to either FARM or VAULT 
    function _depositAsset(address deployAddress, bool useVault, bool useFarm, uint256 farmType ,uint256 pid ,uint256 amt) internal {
        if (useVault == true){
            if (amt > 0){
                Ivault(deployAddress).deposit(amt);
            }
        }
        if (useFarm == true){
            if (amt > 0){
                if (farmType == 0){IFarm(deployAddress).deposit(pid, amt);}
                if (farmType == 1){IGauge(deployAddress).deposit(amt);}
                if (farmType == 2){IFarmPain(deployAddress).deposit(pid, amt, address(this));}
                if (farmType == 3){IFarmPain(deployAddress).deposit(pid, amt, address(this));}
            }
        }



    }

    function _approveNewEarner(address _underlying, address _deployAddress) internal {
        IERC20 underlying = IERC20(_underlying);
        underlying.approve(_deployAddress, uint(-1));
    }

    function _removeApprovals(address _underlying, address _deployAddress) internal {
        IERC20 underlying = IERC20(_underlying);
        underlying.approve(_deployAddress, uint(0));
    }

    function _unlockUnderlying(address deployAddress, bool useVault, bool useFarm, uint256 farmType, uint256 pid) internal {
        if (useVault == true){
            Ivault(deployAddress).withdraw();
        }

        if (useFarm == true){
            if (farmType == 0){IFarm(deployAddress).withdraw(pid, farmBalance(deployAddress, pid));}
            if (farmType == 1){IGauge(deployAddress).withdrawAll();}
            if (farmType == 2){IFarmPain(deployAddress).withdraw(pid, farmBalance(deployAddress, pid), address(this));}
            if (farmType == 3){IFarmPain(deployAddress).withdrawAndHarvest(pid, farmBalance(deployAddress, pid), address(this));}
        }

    }

    function _harvestFarm(address deployAddress, uint256 farmType, uint256 pid) internal {
        if (farmType == 0){IFarm(deployAddress).withdraw(pid, 0);}
        if (farmType == 1){IGauge(deployAddress).getReward();}
        if (farmType == 2){IFarmPain(deployAddress).harvest(pid, address(this));}
        if (farmType == 3){IFarmPain(deployAddress).harvest(pid, address(this));}  
    }

    function getBalanceDeployed(address _deployAddress, bool _useVault, uint256 _pid) public view returns(uint256){
        uint256 balance;
        if (_useVault){
            balance = vaultBalance(_deployAddress);
        } else {
            balance = farmBalance(_deployAddress, _pid);
        }
        return(balance);
    }

    function vaultBalance(address vaultAddress) public view returns(uint256){
        IERC20 vaultToken = IERC20(vaultAddress);
        uint256 vaultDecimals = Ivault(vaultAddress).decimals(); 
        uint256 vaultBPS = 10**vaultDecimals;
        uint256 bal = vaultToken.balanceOf(address(this)).mul(Ivault(vaultAddress).pricePerShare()).div(vaultBPS);
        return(bal);
    }

    function farmBalance(address deployAddress, uint256 pid) public view returns(uint256){
        return IFarm(deployAddress).userInfo(pid, address(this));
    }


    function _zapUniV2(address token, address secondaryToken, address lpAddress ,address zapFrom, address router, uint256 zapAmount) internal {
        address weth = IUniswapV2Router01(router).WETH();
        address[] memory path1 = _getTokenOutPath(address(zapFrom), address(token), weth);
        uint256 amountOutMin = 10;
        IUniswapV2Router01(router).swapExactTokensForTokens(zapAmount.div(2), amountOutMin, path1, address(this), now);

        if (zapFrom != secondaryToken){
            address[] memory path2 = _getTokenOutPath(address(zapFrom), address(secondaryToken), weth);
            IUniswapV2Router01(router).swapExactTokensForTokens(zapAmount.div(2), amountOutMin, path2, address(this), now);
        }

        _addLP(token, secondaryToken, lpAddress, router);

    }

    function _addLP(address _tokenA, address _tokenB, address _lp, address _router) internal {

        IERC20 tokenA = IERC20(_tokenA);
        IERC20 tokenB = IERC20(_tokenB);

        uint256 lpAdj = _calcLPDenominator(_tokenA, _tokenB, _lp);

        uint256 amountADesired = tokenA.balanceOf(_lp).div(lpAdj);
        uint256 amountBDesired = tokenB.balanceOf(_lp).div(lpAdj);

        amountADesired = Math.min(amountADesired, tokenA.balanceOf(address(this)));
        amountBDesired = Math.min(amountBDesired, tokenB.balanceOf(address(this)));

        uint256 amountAMin = amountADesired.mul(95).div(100);
        uint256 amountBMin = amountBDesired.mul(95).div(100);

        IUniswapV2Router01(_router).addLiquidity(_tokenA, _tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, address(this), now);   

    }

    function _calcLPDenominator(address _tokenA, address _tokenB, address _lp) internal returns (uint256){

        IERC20 tokenA = IERC20(_tokenA);
        IERC20 tokenB = IERC20(_tokenB);

        uint256 balanceALP = tokenA.balanceOf(_lp); 
        uint256 balanceBLP = tokenB.balanceOf(_lp);

        uint256 multiplierA = balanceALP.div(tokenA.balanceOf(address(this)));
        uint256 multiplierB = balanceBLP.div(tokenB.balanceOf(address(this)));

        uint256 denominator = Math.max(multiplierA, multiplierB);
        return(denominator);
    }

    function _getTokenOutPath(address _token_in, address _token_out, address _weth)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == _weth || _token_out == _weth;
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = _weth;
            _path[2] = _token_out;
        }
    }

    function _zapBalancerV2(address lpAddress ,address zapFrom, address router, uint256 zapAmount) internal {
        _getPoolInfoAndZap(lpAddress, router , zapAmount, zapFrom);
    }

    
    function _getPoolInfoAndZap(address _balancerPool, address _balancerVault ,uint256 _amountIn, address zapFrom) internal {
        IBalancerPool bpt = IBalancerPool(_balancerPool);
        bytes32 _poolId = bpt.getPoolId();
        IBalancerVault balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens,,) = balancerVault.getPoolTokens(_poolId);
        uint8 numTokens = uint8(tokens.length);
        IAsset[] memory assets =  new IAsset[](numTokens);
        uint8 _tokenIndex;

        for (uint8 i = 0; i < numTokens; i++) {
            if (address(tokens[i]) == zapFrom) {
                _tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }

        uint256[] memory maxAmountsIn = new uint256[](numTokens);
        maxAmountsIn[_tokenIndex] = _amountIn;
        if (_amountIn > 0) {
            bytes memory userData = abi.encode(IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
            IBalancerVault.JoinPoolRequest memory request = IBalancerVault.JoinPoolRequest(assets, maxAmountsIn, userData, false);
            balancerVault.joinPool(_poolId, address(this), address(this), request);
        }

    }
    


}


