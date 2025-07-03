import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from tqdm import tqdm
from datetime import datetime
import warnings
warnings.filterwarnings('ignore')

def get_quantities(liquidity,lower_price,upper_price,pool_price):

    conditional_price=lower_price*(pool_price<=lower_price)+pool_price*((lower_price<pool_price)&(pool_price<upper_price))+upper_price*(upper_price<=pool_price)
    x=liquidity*(1/np.sqrt(conditional_price)-1/np.sqrt(upper_price))
    y=liquidity*(np.sqrt(conditional_price)-np.sqrt(lower_price))

    return x,y

def mint_position(x,y,lower_price,upper_price,pool_price):

    if lower_price<pool_price<upper_price:

        #assume token x is in excess
        position_y=y
        position_liquidity=position_y/(np.sqrt(pool_price)-np.sqrt(lower_price))
        position_x=position_liquidity*(1/np.sqrt(pool_price)-1/np.sqrt(upper_price))

        if x<position_x:  #if token y is actually in excess
            position_x=x
            position_liquidity=position_x/(1/np.sqrt(pool_price)-1/np.sqrt(upper_price))
            position_y=position_liquidity*(np.sqrt(pool_price)-np.sqrt(lower_price))

    elif pool_price<=lower_price:
        position_x=x
        position_liquidity=position_x/(1/np.sqrt(lower_price)-1/np.sqrt(upper_price))
        position_y=0

    else:
        position_y=y
        position_liquidity=position_y/(np.sqrt(upper_price)-np.sqrt(lower_price))
        position_x=0

    return position_liquidity,position_x,position_y

def backtest():

    result=swaps.resample('5Min',on='timestamp').last().ffill().reset_index()[['timestamp','tick']]
    result['tick']=result['tick'].astype(int)
    result['price']=1.0001**result['tick']/10**(decimals_y-decimals_x)
    result=result[(start_date<=result['timestamp'])&(result['timestamp']<end_date)].reset_index(drop=True)
    
    result['fees_x']=0
    result['fees_y']=0
    result['outside_x']=0
    result['outside_y']=0
    result['base_lower_bound_tick']=0
    result['base_upper_bound_tick']=0
    result['base_lower_trigger_tick']=0
    result['base_upper_trigger_tick']=0
    result['base_liquidity']=0
    result['limit_lower_bound_tick']=0
    result['limit_upper_bound_tick']=0
    result['limit_lower_trigger_tick']=0
    result['limit_upper_trigger_tick']=0
    result['limit_liquidity']=0
    result['rebalance']=False
    result['reason']=None
    result['lent']=0
    result['borrowed']=0

    for i in tqdm(range(len(result)-1)):

        pool_tick=result['tick'][i]
        pool_price=result['price'][i]

        #liquidity
        base_liquidity=result['base_liquidity'][i]
        limit_liquidity=result['limit_liquidity'][i]

        #position bounds
        base_lower_bound_tick=result['base_lower_bound_tick'][i]
        base_upper_bound_tick=result['base_upper_bound_tick'][i]
        limit_lower_bound_tick=result['limit_lower_bound_tick'][i]
        limit_upper_bound_tick=result['limit_upper_bound_tick'][i]

        #corresponding prices
        base_lower_bound_price=1.0001**base_lower_bound_tick/10**(decimals_y-decimals_x)
        base_upper_bound_price=1.0001**base_upper_bound_tick/10**(decimals_y-decimals_x)
        limit_lower_bound_price=1.0001**limit_lower_bound_tick/10**(decimals_y-decimals_x)
        limit_upper_bound_price=1.0001**limit_upper_bound_tick/10**(decimals_y-decimals_x)

        #position tokens
        base_x,base_y=get_quantities(base_liquidity,base_lower_bound_price,base_upper_bound_price,pool_price)
        limit_x,limit_y=get_quantities(limit_liquidity,limit_lower_bound_price,limit_upper_bound_price,pool_price)

        #fees
        swaps_period=swaps[(result['timestamp'][i]<=swaps['timestamp'])&(swaps['timestamp']<result['timestamp'][i+1])]
        swaps_period['gamma_liquidity']=base_liquidity*((base_lower_bound_tick<=swaps_period['tick'])&(swaps_period['tick']<base_upper_bound_tick))+limit_liquidity*((limit_lower_bound_tick<=swaps_period['tick'])&(swaps_period['tick']<limit_upper_bound_tick))
        swaps_period['gamma_share']=swaps_period['gamma_liquidity']/(swaps_period['gamma_liquidity']+swaps_period['liquidity'])
        fees_x=(swaps_period['gamma_share']*swaps_period['fees_x']).sum()
        fees_y=(swaps_period['gamma_share']*swaps_period['fees_y']).sum()
        outside_x=result['outside_x'][i]+fees_x
        outside_y=result['outside_y'][i]+fees_y

        #base trigger
        base_lower_trigger_tick=int(base_lower_bound_tick-base_lower_trigger_ticks)
        base_upper_trigger_tick=int(base_upper_bound_tick+base_upper_trigger_ticks)
        base_triggered=not base_lower_trigger_tick<=pool_tick<base_upper_trigger_tick

        #limit trigger
        limit_lower_trigger_tick=int(limit_lower_bound_tick-limit_trigger_ticks)
        limit_upper_trigger_tick=int(limit_upper_bound_tick+limit_trigger_ticks)
        limit_triggered=not limit_lower_trigger_tick<=pool_tick<limit_upper_trigger_tick

        #values
        base_value=base_x*pool_price+base_y
        limit_value=limit_x*pool_price+limit_y
        outside_value=outside_x*pool_price+outside_y
        outside_base_value=limit_value+outside_value
        total_value=base_value+limit_value+outside_value

        #hedging
        lent=result['lent'][i]
        borrowed=result['borrowed'][i]
        delta=-borrowed+base_x+limit_x+outside_x
        current_position=1*(base_upper_bound_tick==887272//spacing*spacing)-1*(base_lower_bound_tick==-887272//spacing*spacing+spacing)
        target_position=1*(delta/borrowed<-delta_threshold)-1*(delta_threshold<delta/borrowed)

        ###check for rebalance

        rebalance=False
        reason=None

        if limit_triggered:
            rebalance=True
            reason='limit_trigger'
        if base_triggered:
            rebalance=True
            reason='base_trigger'
        if current_position!=target_position:
            rebalance=True
            reason='delta'

        #initialization
        if i==0:
            rebalance=True
            reason='initialization'
            lent=start_value*2/3
            borrowed=lent/2/pool_price
            outside_x=borrowed
            outside_y=start_value-lent

        if rebalance:

            #burn all
            outside_x+=base_x+limit_x
            outside_y+=base_y+limit_y

            if reason in ['base_trigger','delta','initialization']:

                #set new base bounds
                base_lower_bound_tick=(-887272//spacing*spacing+spacing)*(target_position==-1)+int((pool_tick-base_lower_bound_ticks)//spacing*spacing)*(target_position in [0,1])
                base_upper_bound_tick=int((pool_tick+base_upper_bound_ticks)//spacing*spacing)*(target_position in [-1,0])+(887272//spacing*spacing)*(target_position==1)

                #compute corresponding prices
                base_lower_bound_price=1.0001**base_lower_bound_tick/10**(decimals_y-decimals_x)
                base_upper_bound_price=1.0001**base_upper_bound_tick/10**(decimals_y-decimals_x)

            #mint base
            base_liquidity,base_x,base_y=mint_position(outside_x,outside_y,base_lower_bound_price,base_upper_bound_price,pool_price)
            outside_x-=base_x
            outside_y-=base_y

            #set new limit bounds
            limit_lower_bound_tick=(-887272//spacing*spacing+spacing)*(target_position==-1)+int((pool_tick-limit_bound_ticks)//spacing*spacing)*(target_position in [0,1])
            limit_upper_bound_tick=int((pool_tick+limit_bound_ticks)//spacing*spacing)*(target_position in [-1,0])+(887272//spacing*spacing)*(target_position==1)

            #adjust limit bounds to pool tick
            limit_lower_bound_tick=min(limit_lower_bound_tick,pool_tick//spacing*spacing-spacing)
            limit_upper_bound_tick=max(limit_upper_bound_tick,pool_tick//spacing*spacing+2*spacing)

            #adjust limit bounds to remaining token
            if outside_y==0: limit_lower_bound_tick=pool_tick//spacing*spacing+spacing
            else: limit_upper_bound_tick=pool_tick//spacing*spacing

            #corresponding prices
            limit_lower_bound_price=1.0001**limit_lower_bound_tick/10**(decimals_y-decimals_x)
            limit_upper_bound_price=1.0001**limit_upper_bound_tick/10**(decimals_y-decimals_x)

            #mint limit
            limit_liquidity,limit_x,limit_y=mint_position(outside_x,outside_y,limit_lower_bound_price,limit_upper_bound_price,pool_price)
            outside_x-=limit_x
            outside_y-=limit_y

        result['fees_x'][i]=fees_x
        result['fees_y'][i]=fees_y
        result['outside_x'][i+1]=outside_x
        result['outside_y'][i+1]=outside_y
        result['base_lower_bound_tick'][i+1]=base_lower_bound_tick
        result['base_upper_bound_tick'][i+1]=base_upper_bound_tick
        result['base_lower_trigger_tick'][i]=base_lower_trigger_tick
        result['base_upper_trigger_tick'][i]=base_upper_trigger_tick
        result['base_liquidity'][i+1]=base_liquidity
        result['limit_lower_bound_tick'][i+1]=limit_lower_bound_tick
        result['limit_upper_bound_tick'][i+1]=limit_upper_bound_tick
        result['limit_lower_trigger_tick'][i]=limit_lower_trigger_tick
        result['limit_upper_trigger_tick'][i]=limit_upper_trigger_tick
        result['limit_liquidity'][i+1]=limit_liquidity
        result['rebalance'][i]=rebalance
        result['reason'][i]=reason
        result['lent'][i+1]=lent*(1+lending_apy)**(1/(365*24*12))
        result['borrowed'][i+1]=borrowed*(1+borrowing_apy)**(1/(365*24*12))

    pool_price=result['price']

    #base
    base_liquidity=result['base_liquidity']
    base_lower_bound_tick=result['base_lower_bound_tick']
    base_upper_bound_tick=result['base_upper_bound_tick']
    base_lower_bound_price=1.0001**base_lower_bound_tick/10**(decimals_y-decimals_x)
    base_upper_bound_price=1.0001**base_upper_bound_tick/10**(decimals_y-decimals_x)
    base_x,base_y=get_quantities(base_liquidity,base_lower_bound_price,base_upper_bound_price,pool_price)
    result['base_value']=base_x*pool_price+base_y

    #limit
    limit_liquidity=result['limit_liquidity']
    limit_lower_bound_tick=result['limit_lower_bound_tick']
    limit_upper_bound_tick=result['limit_upper_bound_tick']
    limit_lower_bound_price=1.0001**limit_lower_bound_tick/10**(decimals_y-decimals_x)
    limit_upper_bound_price=1.0001**limit_upper_bound_tick/10**(decimals_y-decimals_x)
    limit_x,limit_y=get_quantities(limit_liquidity,limit_lower_bound_price,limit_upper_bound_price,pool_price)
    result['limit_value']=limit_x*pool_price+limit_y

    result['outside_value']=result['outside_x']*pool_price+result['outside_y']
    result['fees_value']=result['fees_x']*pool_price+result['fees_y']
    result['liquidity_value']=result['base_value']+result['limit_value']+result['outside_value']+result['fees_value']

    result['base_ratio']=result['base_value']/result['liquidity_value']
    result['limit_ratio']=result['limit_value']/result['liquidity_value']

    result['total_value']=result['liquidity_value']+result['lent']-result['borrowed']*pool_price
    result['return']=result['total_value']/result['total_value'].shift(1)-1

    result['normalized_delta']=(-result['borrowed']+base_x+limit_x+result['outside_x']+result['fees_x'])/result['borrowed']
    result['health_factor']=result['lent']*liquidation_threshold/(result['borrowed']*pool_price)

    result=result[2:-1]

    return result

#pool
decimals_x=18
decimals_y=6
spacing=60
start_value=1

#swaps
swaps=pd.read_csv('swaps.csv')
swaps['timestamp']=pd.to_datetime(swaps['timestamp'],format='%Y-%m-%d %H:%M:%S')

#strategy
delta_threshold=0.1
base_lower_bound_ticks=300
base_upper_bound_ticks=300
base_lower_trigger_ticks=-30
base_upper_trigger_ticks=-30
limit_bound_ticks=400
limit_trigger_ticks=150

#lending
liquidation_threshold=0.8
lending_apy=0.05
borrowing_apy=0.02

#dates
start_date=datetime.strptime('01/01/2024','%d/%m/%Y')
end_date=datetime.strptime('01/07/2025','%d/%m/%Y')

result=backtest()

#metrics
rebalances=int((result['rebalance']==True).sum())
drawdown=result['total_value'].div(result['total_value'].cummax()).sub(1).min()
apy=(result['total_value'].iloc[-1]/result['total_value'].iloc[0])**(365*24*12/len(result))-1
calmar=-apy/drawdown
sharpe=result['return'].mean()/result['return'].std()*((365*24*12)**0.5)

print('rebalances: '+str(rebalances))
print('apy: '+str(apy))
print('drawdown: '+str(drawdown))
print('calmar: '+str(calmar))
print('sharpe: '+str(sharpe))

#plot positions
plt.plot(result['timestamp'],result['tick'],color='black',linewidth=1,label='pool')
plt.fill_between(result['timestamp'],result['base_upper_bound_tick'],result['base_lower_bound_tick'],color='black',alpha=0.1,label='base bounds')
plt.plot(result['timestamp'],result['base_upper_trigger_tick'],':',color='black',label='base triggers')
plt.plot(result['timestamp'],result['base_lower_trigger_tick'],':',color='black')
plt.fill_between(result['timestamp'],result['limit_upper_bound_tick'],result['limit_lower_bound_tick'],color='red',alpha=0.3,label='limit bounds')
plt.plot(result['timestamp'],result['limit_upper_trigger_tick'],':',color='red',label='limit triggers')
plt.plot(result['timestamp'],result['limit_lower_trigger_tick'],':',color='red')
plt.title('positions')
plt.legend(prop={'size':8})
plt.xticks(rotation=45)
plt.grid(False)
plt.tight_layout()
plt.savefig('positions.png',dpi=300)
plt.show()

#plot value
plt.plot(result['timestamp'],result['price']/result['price'].iloc[0],color='black',linewidth=1,label='hold x')
plt.plot(result['timestamp'],result['total_value'],color='red',linewidth=1,label='strategy')
plt.title('value')
plt.ylabel('y')
plt.legend(prop={'size':8})
plt.xticks(rotation=45)
plt.grid(False)
plt.tight_layout()
plt.savefig('value.png',dpi=300)
plt.show()

#plot normalized delta
plt.plot(result['timestamp'],result['normalized_delta'],color='black',linewidth=1)
plt.title('normalized delta')
plt.xticks(rotation=45)
plt.grid(False)
plt.tight_layout()
plt.savefig('delta.png',dpi=300)
plt.show()

#plot health factor
plt.plot(result['timestamp'],result['health_factor'],color='black',linewidth=1)
plt.title('health factor')
plt.xticks(rotation=45)
plt.grid(False)
plt.tight_layout()
plt.savefig('health.png',dpi=300)
plt.show()