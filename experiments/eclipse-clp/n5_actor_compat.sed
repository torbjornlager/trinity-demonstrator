# ECLiPSe reads an underscore in a number as base notation.
s/1_000_000/1000000/g
# N7 uses the bare address from the final N5 layer.
/^linda_local_address(/d
