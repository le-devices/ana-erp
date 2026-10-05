# ana:description Programa de demonstração (bom para experimentar o depurador)
# ana:exposed yes
# ana:command hello
"""Greets and does a little math — set a breakpoint and debug it!"""

PARAMS = {
    "name": {"type": "str", "default": "mundo"},
    "times": {"type": "int", "default": 3},
}


def square(n):
    result = n * n
    return result


def main(name="mundo", times=3):
    total = 0
    for i in range(1, times + 1):
        q = square(i)
        total += q
        print(f"{i}² = {q}")
    # ana:lint-ok unbounded_select — demonstration: counts the item master
    products = ana.sql_value("SELECT count(*) FROM base.product")
    ana.log(f"existem {products} itens cadastrados")
    return {"message": f"Olá, {name}!", "sum_of_squares": total}
