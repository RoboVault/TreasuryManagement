import brownie
from brownie import Contract, interface, accounts, reverts
import pytest

"""
testing functionality of treasury 
to run type below in terminal : 
brownie test ./tests/testTreasury.py --network ftm-main-fork -s -x -i
"""

@pytest.fixture
def treasuryContract(treasury):
    wftm = interface.ERC20('0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83')
    yield treasury.deploy(wftm, {"from": accounts[0]})

def testPermissions(treasuryContract): 
    user = accounts[1]
    usdc = interface.ERC20('0x04068DA6C83AFCFA0e13ba15A6696662335D5B75')
    yvUSDC = '0xEF0210eB96c7EB36AF8ed1c20306462764935607'
    wftm = interface.ERC20('0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83')
    router = '0xF491e7B69E4244ad4002BC14e878a34207E38c29'
    
    with reverts():
        treasuryContract.addAsset(usdc,{"from" : user})

    with reverts():
        treasuryContract.addVault(usdc,50,yvUSDC,{"from" : user})





def testVault(treasuryContract, chain):
    usdc = interface.ERC20('0x04068DA6C83AFCFA0e13ba15A6696662335D5B75')
    # two vaults to deposit into 
    yvUSDC = '0xEF0210eB96c7EB36AF8ed1c20306462764935607'
    rvUSDCb = '0xa9BE8Ea19aAC1966fd4a7dCc418d07E0b1716d8C'
    usdcWhale = '0x04068DA6C83AFCFA0e13ba15A6696662335D5B75'
    owner = accounts[0]

    usdcTransfer = 1000*(10**6)

    print("Transfer assets - to simulate bonds")
    usdc.transfer(treasuryContract, usdcTransfer,  {"from" : usdcWhale})
    print("Add Vault Details")
    treasuryContract.addAsset(usdc,{"from" : owner})
    treasuryContract.addVault(usdc,50,yvUSDC,{"from" : owner})
    treasuryContract.addVault(usdc,50,rvUSDCb,{"from" : owner})


    print("Check Vault deposits & withdrawals work")
    treasuryContract.deployAssets({"from" : owner})
    assert usdc.balanceOf(treasuryContract) == 0 
    chain.sleep(10)

    treasuryContract.undeployAssets({"from" : owner})
    assert usdc.balanceOf(treasuryContract) >= usdcTransfer


def testLP(treasuryContract, chain):

    wftm = interface.ERC20('0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83')

    lpWhale = '0x51D493C9788F4b6F87EAe50F555DD671c4Cf653E'
    lpTransferAmt = 0 
    lp = interface.ERC20('0xcdE5a11a4ACB4eE4c805352Cec57E236bdBC3837')
    beets = interface.ERC20('0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e')
    beetsRouter = '0x20dd72Ed959b6147912C2e529F0a0C651c33c9ce'
    beetsMasterChef = '0x8166994d9ebBe5829EC86Bd81258149B87faCfd3'
    beetsPid = 9

    lp.transfer(lpWhale, lpTransferAmt,  {"from" : lpWhale})


    owner = accounts[0]
    strategist = accounts[1]
    print("Add LP Details to be zapped into")
    treasuryContract.addAsset(lp,{"from" : owner})

    print("Check Farm Deposits & Withdrawals")

    treasuryContract.addFarm(lp, 100, beetsMasterChef, 3 ,beetsPid)
    treasuryContract.deployAssets({"from" : owner})
    assert lp.balanceOf(treasuryContract) == 0
    treasuryContract.undeployAssets({"from" : owner})
    assert lp.balanceOf(treasuryContract) > 0

    print("Check farming works")


    beetsPreHarvest = beets.balanceOf(treasuryContract)

    treasuryContract.deployAssets({"from" : owner})
    chain.sleep(1000)
    treasuryContract.harvestRewards({"from" : owner})

    #need to confirm how beets masterchef + spirit gauges work as harvesting doesn't seem to be giving any tokens
    """
    assert beets.balanceOf(treasuryContract) > beetsPreHarvest
    """
