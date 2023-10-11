# SpectralBarrierMethod

## Author: Sébastien Loisel

The Spectral Barrier Method: spectral solution to highly nonlinear convex PDEs

To solve a p-Laplace equation in 1d, do:

```
julia> using SpectralBarrierMethod; SOL=test1(Float64,n=7,p=1.1);
```

To solve a p-Laplace equation in 2d, do:

```
julia> using SpectralBarrierMethod; SOL=test2(Float64,n=7,p=1.1);
```

To see some more examples, look at the source code for `test1` and `test2`.
