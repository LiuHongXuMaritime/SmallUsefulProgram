import math

# GTValues.V[5] << 1，在 GTNH 里通常是 16384
BASE_L_EUT = 16384

def cbrt(x):
    return math.copysign(abs(x) ** (1.0 / 3.0), x)

def calc_eu_production(energy_t, boost):
    """
    对应代码里的 setEUProduction()
    energy_t: 已经除以 20 后的 EU/t 输入能量，整数
    boost: 是否开启 boost
    """
    energy = int(energy_t)

    if energy > 30000:
        t_divide = cbrt(energy)
        energy_efficiency = 31.072325 / t_divide

        if energy >= 80000:
            energy_efficiency *= 43.0886938 / t_divide

        energy_efficiency *= energy
    else:
        energy_efficiency = float(energy)

    eu_production = int(energy_efficiency)  # Java 的 (int) 是截断

    if boost:
        eu_production *= 3

    return eu_production


def calculate(special_value, fuel_per_sec, boost=False):
    """
    special_value: 火箭燃料配方的 mSpecialValue
    fuel_per_sec: 实际燃料消耗 L/s，对应代码里的 fuelConsumption
    boost: 是否成功开启 boost
    """
    fuel_value = special_value * 3  # EU/L

    if boost:
        # 代码里 amount = int(raw * 0.3)，实际消耗 = amount * 3
        # 所以给定实际消耗 fuel_per_sec，amount = fuel_per_sec // 3
        amount = int(fuel_per_sec) // 3
        actual_fuel = amount * 3
    else:
        # 代码里 amount = int(raw * 0.9)，实际消耗 = amount
        amount = int(fuel_per_sec)
        actual_fuel = amount

    if amount < 5:
        return {
            "错误": "amount < 5，代码会返回 false，不消耗燃料，不发电"
        }

    energy_per_sec = fuel_value * amount  # EU/s
    energy_t = energy_per_sec // 20       # EU/t，整数除法

    eu_prod = calc_eu_production(energy_t, boost)

    # 最终实际最大输出：lEUt = 16384，mEfficiency 上限 = euProduction
    actual_output = BASE_L_EUT * eu_prod // 10000  # EU/t

    # 消耗计算
    air_per_tick = eu_prod // 100
    air_per_sec = air_per_tick * 20

    co2_per_hour = 1000 * (3 if boost else 1)
    loh_per_sec = (3 * eu_prod) // 1000
    pollution_per_sec = 1500 * (eu_prod // 10000)

    return {
        "燃料值 EU/L": fuel_value,
        "实际燃料消耗 L/s": actual_fuel,
        "能量输入 EU/s": energy_per_sec,
        "能量输入 EU/t": energy_t,
        "euProduction": eu_prod,
        "理论最大实际输出 EU/t": actual_output,
        "空气消耗 L/s": air_per_sec,
        "CO2 消耗 L/h": co2_per_hour,
        "液氢消耗 L/s": loh_per_sec,
        "污染 gibbl/s": pollution_per_sec,
        "启动提示": (
            "约 100 秒达到最大效率"
            if eu_prod >= 2000
            else "euProduction < 2000，mEfficiencyIncrease = 0，无法启动"
        ),
    }


def raw_to_consumption(raw_fuel, boost):
    """
    如果你知道的是输入仓里某次消耗前的燃料总量 raw_fuel，
    可以用这个函数算出实际消耗 L/s。
    """
    if boost:
        amount = int(raw_fuel * 0.3)
        return amount * 3
    else:
        return int(raw_fuel * 0.9)


if __name__ == "__main__":
    # 示例 1：假设燃料 mSpecialValue = 100，每秒实际消耗 100L，不开 boost
    result = calculate(special_value=6144/3, fuel_per_sec=1025, boost=False)
    for k, v in result.items():
        print(f"{k}: {v}")

    print("-" * 40)

    # 示例 2：同样条件，开启 boost
    result = calculate(special_value=6144/3, fuel_per_sec=1025, boost=True)
    for k, v in result.items():
        print(f"{k}: {v}")