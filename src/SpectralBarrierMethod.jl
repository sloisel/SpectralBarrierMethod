module SpectralBarrierMethod
using ForwardDiff
using SparseArrays
using LinearAlgebra
#Pkg.add(url="https://github.com/billmclean/GaussQuadrature.jl.git")
using PyPlot
using ProgressMeter
using QuadratureRules

export Mesh, Barrier, barrier, spb, spectralmesh, spectralmesh2d, test1, test2, interp1d, interp2d, plot1d, plot2d

"""
    Mesh{T}

A type for holding spectral meshes. Fields are:

    w::Array{T,2}
    x::Array{T,2}
    n::Int
    D
    R

* `x` contains quadrature nodes. For d=1 dimensional meshes, this is a column vector. For d=2 dimensional meshes, `x` is an n by 2 array, each row being a vertex in the plane. We use Clenshaw-Curtis quadrature.
* `w` contains quadrature weights. Specifically, `w[:,end]` has the quadrature weights for the highest possible degree quadrature. The other columns `w[:,k]` have lower degree quadrature rules, so that one has a hierarchy of embedded quadrature rules.
* `n` the "desired" number of quadrature nodes along each axis. It may be that `size(x,1)>n^d` since we generate embedded quadrature rules.
* `D` an array of differential operator. In 1d, D[q,s] = [q,q',s]. In 2d, D[q,s] = [q,q_x,q_y,s].
* `R` an array. Each `R[k]` is a matrix whose columns form a basis for polynomials of a certain degree satisfying certain boundary conditions.
"""
@kwdef struct Mesh{T}
    w::Array{T,2}
    x::Array{T,2}
    n::Int
    D
    R
#    interp::Function
#    plot::Function
end

"""
    Barrier{T}

A type for holding barrier functions. Fields are:

    f0::Function
    f1::Function
    f2::Function
    M::Mesh{T}

`f0` is the barrier function itself, while `f1` is its gradient and
`f2` is the Hessian.
"""
@kwdef struct Barrier{T}
    f0::Function
    f1::Function
    f2::Function
    M::Mesh{T}
end

"""
    function barrier(M::Mesh{T},f;
        f1=(x,y)->ForwardDiff.gradient(z->f(x,z),y),
        f2=(x,y)->ForwardDiff.hessian(z->f(x,z),y))::Barrier{T} where {T}

Constructor for barriers.

* `M` is the underlying mesh.
* `f` is the actual barrier function. It should take parameters `(x,y)`.
* `f1` is the gradient of `f` with respect to `y`.
* `f2` is the Hessian of `f` with  respect to `y`.

By default, `f1` and `f2` are automatically generated by the module `ForwardDiff`.
"""
function barrier(M::Mesh{T},f;
        f1=(x,y)->ForwardDiff.gradient(z->f(x,z),y),
        f2=(x,y)->ForwardDiff.hessian(z->f(x,z),y))::Barrier{T} where {T}
    w=M.w
    (m1,m2) = size(M.D[1])
    w2 = repeat(w,Int(m2/m1))
    x=M.x
    D=M.D
    @assert all(isfinite.(w))
    @assert all(isfinite.(x))
    p = size(x,1)
    n = length(D)
    m = size(D[1],2)
    Dz = Array{T,2}(undef,(p,n))
    function make_params(z)
        for k=1:n
            Dz[:,k] = (D[k]*z)::Array{T,1}
        end
    end
    y = Array{T,3}(undef,(p,n,n))
    function F0(L::Integer,c::Array{T,1},z::Array{T,1})
        @assert all(isfinite.(z))
        make_params(z)
        for i=1:p
            if w[i,L] == 0
                y[i,1,1] = 0
            else
                y[i,1,1] = f(x[i,:],Dz[i,:])
            end
        end
        dot(w[:,L],y[:,1,1])+dot(w2[:,L].*c,z)
    end
    function F1(L::Integer,c::Array{T,1},z::Array{T,1})
        @assert all(isfinite.(z))
        make_params(z)
        for i=1:p
            if w[i,L] == 0
                y[i,:,1] .= 0
            else
                y[i,:,1] = f1(x[i,:],Dz[i,:])
            end
        end
        ret = w2[:,L].*c
        for k=1:n
            ret += D[k]'*(w[:,L].*y[:,k,1])
        end
        ret
    end
    function F2(L::Integer,c::Array{T,1},z::Array{T,1})
        @assert all(isfinite.(z))
        make_params(z)
        ret = spzeros(T,m,m)
        for i=1:p
            if w[i,L] == 0
                y[i,:,:] .= 0
            else
                y[i,:,:] = f2(x[i,:],Dz[i,:])
            end
        end
        for j=1:n
            foo = spdiagm(0=>w[:,L].*y[:,j,j])
            ret += (D[j])'*foo*D[j]
            for k=1:j-1
                foo = spdiagm(0=>w[:,L].*y[:,j,k])
                ret += D[j]'*foo*D[k] + D[k]'*foo*D[j]
            end
        end
        ret
    end
    Barrier{T}(f0=F0,f1=F1,f2=F2,M=M)
end

"""
    function damped_newton(F0::Function,
                       F1::Function,
                       F2::Function,
                       x::Array{T,1},
                       R;
                       maxit=10000,
                       alpha=T(0.1),
                       beta=T(0.25),
                       tol=eps(T)^(2/3)) where {T}

Damped Newton iteration for minimizing a function in the space `x`+span `R`.

* `F0` the objective function
* `F1` and `F2` are the gradient and Hessian of `F0`, respectively.
* `x` the starting point of the minimization procedure.
* `R` a matrix whose columns generate a "search space".

The optional parameters are:
* `maxit`, the iteration aborts with a failure message if convergence is not achieved within `maxit` iterations.
* `alpha` and `beta` are the parameters of the backtracking line search.
* `tol` is used as a stopping criterion. We stop when the decrement in the objective is sufficiently small.
"""
function damped_newton(F0::Function,
                       F1::Function,
                       F2::Function,
                       x::Array{T,1},
                       R;
                       maxit=10000,
                       alpha=T(0.1),
                       beta=T(0.25),
                       tol=eps(T)^(2/3)) where {T}
    ss = []
    ys = []
    @assert all(isfinite.(x))
    y = F0(x) ::T
    @assert isfinite(y)
    push!(ys,y)
    converged = false
    k = 0
    while k<maxit
        k+=1
        xprev = x
        yprev = y
        g = R'*F1(x)::Array{T,1}
        @assert all(isfinite.(g))
        H = R'*F2(x)*R
        n = ((H+I*norm(H)*eps(T))\g)::Array{T,1}
        @assert all(isfinite.(n))
        inc = dot(g,n)
        if inc<=0
            converged = true
            break
        end
        s = T(1)
        n = R*n
        for j=1:maxit
            x = xprev-s*n ::Array{T,1}
            @assert all(isfinite.(x))
            if x==xprev
                break
            end
            try
                y = F0(x) ::T
                if(isfinite(y) && y<yprev-s*alpha*inc)
                    break
                end
            catch
            end
            s = s*beta
            x = xprev
            y = yprev
        end
        push!(ss,s)
        push!(ys,y)
        if yprev-y<=tol*max((min(abs(yprev),abs(y))),1)
            converged = true
            break
        end
    end
    return (x=x,y=y,k=k,converged=converged,
                        ss=ss,ys=ys)
end
function spb_phase_1(B::Barrier{T},
             c::Array{T,1},
             x::Array{T,1};
             maxit=10000,
             alpha=T(0.1),
             beta=T(0.25)) where {T}
    its = zeros(Int,length(B.M.R))
    L1 = length(B.M.R)
    yprev = B.f0(L1,c,x)
    for L=1:length(B.M.R)
        SOL = damped_newton(x->B.f0(L,c,x),x->B.f1(L,c,x),x->B.f2(L,c,x),
            x,B.M.R[L],maxit=maxit,alpha=alpha,beta=beta)
        its[L] = SOL.k
        pass = true
        try
            y0 = B.f0(L1,c,SOL.x)::T
            y1 = B.f1(L1,c,SOL.x)::Array{T,1}
            pass = isfinite(y0) && all(isfinite.(y1)) && SOL.converged && y0<yprev
        catch
            pass = false
        end
        if pass
            x = SOL.x
        end
    end
    return (x=x,its=its,
            B=B,c=c,maxit=maxit,
            alpha=alpha,beta=beta)
end

"""
    function spb(B::Barrier{T},
             c::Array{T,1},
             x::Array{T,1};
             t=T(0.01),
             tol=sqrt(eps(T)),
             kappa=T(10.0),
             maxit=10000,
             maxnewton=Int(ceil(log2(-log2(eps(T)))))+2,
             alpha=T(0.1),
             beta=T(0.25),
             verbose=true) where {T}

The SPectral Barrier method.

* `B` a barrier object.
* `c` an objective functional to minimize. Concretely, we minimize the integral of `c.*x`, as computed by the finest quadrature in `B`, subject to `B.f0(x)<∞`.
* `x` a starting point for the minimization, which should be admissible, i.e. `B.f0(x)<∞`.

Optional parameters:

* `t`: the initial value of `t`
* `tol`: we stop when `1/t<tol`.
* `kappa`: the initial t-step size.
* `maxit`: the maximum number of `t` steps.
* `maxnewton`: the maximum number of Newton steps used for most `t`-steps, except for the preliminary phase.
* `alpha`, `beta`: parameters of the backtracking line search.
* `verbose`: set to `true` to see a progress bar.
"""
function spb(B::Barrier{T},
             c::Array{T,1},
             x::Array{T,1};
             t=T(0.01),
             tol=sqrt(eps(T)),
             kappa=T(10.0),
             maxit=10000,
             maxnewton=Int(ceil(log2(-log2(eps(T)))))+2,
             alpha=T(0.1),
             beta=T(0.25),
             verbose=true) where {T}
    t_begin = time()
    F0 = B.f0
    F1 = B.f1
    F2 = B.f2
    R = B.M.R
    L = length(R)
    k=1
    its = zeros(Int,(L+1,maxit))
    kappas = zeros(T,maxit)
    ts = zeros(T,maxit)
    converged=false
    tinit = t
    ts[1] = t
    kappas[1] = kappa
    pbar = 0
    if verbose
        pbar = Progress(100; dt=1.0)
    end
    SOL = spb_phase_1(B,t*c,x;
             maxit=10000,alpha=T(0.1),beta=T(0.25))
    its[2:end,1] = SOL.its
    x = SOL.x
    xprev = x
    kappa_init = kappa
    t = "hi"
    while(k<maxit)
        k+=1
        ts[k] = ts[k-1]*kappa
        if verbose
            percent = 100*((log(ts[k-1])-log(tinit))/(log(1/tol)-log(tinit)))
            update!(pbar,Int(floor(percent)))
        end
        SOL = damped_newton(x->F0(L,ts[k]*c,x),x->F1(L,ts[k]*c,x),x->F2(L,ts[k]*c,x),
                       x,R[end],maxit=maxnewton,alpha=alpha,beta=beta)
        its[1,k] += SOL.k
        if(SOL.converged)
            x = SOL.x
            if SOL.k<=maxnewton*0.5
                kappa = min(kappa_init,kappa^2)
            end
        else
            cvg = true
            for j=1:maxit
                x = xprev
                @assert kappa>1
                ts[k] = ts[k-1]*kappa
                cvg = true
                for i=1:length(R)
                    if k<=2
                        mi = maxit
                    else
                        mi = maxnewton
                    end
                    SOL = damped_newton(x->F0(L,ts[k]*c,x),x->F1(L,ts[k]*c,x),x->F2(L,ts[k]*c,x),
                       x,R[i],maxit=mi,alpha=alpha,beta=beta)
                    its[i+1,k] += SOL.k
                    if(!SOL.converged)
                        kappa = sqrt(kappa)
                        cvg = false
                        break
                    end
                    x = SOL.x
                end
                if(cvg)
                    break
                end
            end
            if !cvg
                break
            end
        end
        kappas[k] = kappa
        xprev = x
        if(1/ts[k]<tol)
            converged=true
            break
        end
    end
    if verbose
        update!(pbar,100)
        finish!(pbar)
    end
    its = its[:,1:k]
    kappas = kappas[1:k]
    ts = ts[1:k]
    @assert all(ts[2:k]>ts[1:k-1])
    t_end = time()
    t_elapsed = t_end-t_begin
    return (x=x,k=k,converged=converged,its=its,
            kappas=kappas,ts=ts,maxnewton=maxnewton,
            B=B,c=c,tol=tol,maxit=maxit,
            alpha=alpha,beta=beta,verbose=verbose,
            t_begin=t_begin,t_end=t_end,t_elapsed=t_elapsed)
end

function chebfun(c::Array{T,2}, x::T) where {T}
    n = size(c,1)-1
    m = size(c,2)
    if x>1
        return c'*cosh.((0:n).*acosh(x))
    elseif x>=-1
        return c'*cos.((0:n).*acos(x))
    end
    s = ones(T,n)
    s[2:2:n] .= T(-1)
    return c'*(s.*cosh.((0:n).*acosh(-x)))
end
function chebfun(c::Array{T}, x::Array{T}) where {T}
    sc = size(c)
    sx = size(x)
    c = reshape(c,(sc[1],:))
    m = size(c,2)
    n = prod(sx)
    x = reshape(x,n)
    y = zeros(T,n,m)
    for k=1:n
        y[k,:] = chebfun(c,x[k])
    end
    if length(sc)==1
        return reshape(y,sx)
    end
    return reshape(y,(sx...,sc[2:end]...))
end
chebfun(c::Array{T,1}, x::T) where {T} = chebfun(c,[x])[1]

function derivative(::Type{T},n::Integer) where {T}
    D = zeros(T,(n,n))
    for j=1:n-1
        for k=j+1:2:n
            D[j,k] = 2*(k-1)
        end
    end
    D[1,:]/=2
    D
end
derivative(n::Integer) = derivative(Float64,n)

function evaluation(xs::Array{T},n::Integer) where {T}
    m = size(xs,1)
    n = n-1
    M = zeros(T,(m,n+1))
    for j=1:m
        x = xs[j]
        if x>1
            M[j,:] = cosh.((0:n).*acosh(x))
        elseif x>=-1
            M[j,:] = cos.((0:n).*acos(x))
        else
            s = ones(T,n+1)
            s[2:2:n+1] .= T(-1)
            M[j,:] = s.*cosh.((0:n).*acosh(-x))
        end
    end
    M
end

"""
    function spectralmesh(::Type{T}, n::Integer; roundup=true) where {T}

Constructor for `Mesh{T}` objects. This creates a d=1 dimensional mesh, i.e.
on the interval [-1,1].

* `roundup`: set to `true` to "round up" the number of grid points so that `n-1` is a power of 2.
* `n`: the desired number of grid points.

This function creates a 1d Clenshaw-Curtis mesh, but also a hierarchy of meshes
obtained by recursive subdivision. This exploits the fact that Clenshaw-Curtis nodes
are nested.

Thus, the number `m1` of rows of `M.w` will satisfy that `m1-1` is a power of 2.
If `roundup` is `true` then `n` will be set to `m1`. If `roundup` is set to `false`,
then `n` will not be set to `m1` and it may be that `n<m1`. In any case, the 
"fine grid" `R[end]` will represent polynomials of max degree `n`, which may be less
than `m1`.

In most cases, you want to set `roundup=true` so that `n=m1`, but I use the
situation `n<m1` for scaling experiments.
"""
function spectralmesh(::Type{T}, n::Integer; roundup=true) where {T}
#    x, w = legendre(T,n)
    m1 = 2
    ww = []
    k = 0
    x = 0
    Js = []
    while m1<n
        m1 = 2*m1-1
        k += 1
        push!(Js,m1)
        wprev = ww
        ww = zeros(T,(m1,k))
        if k>1
            ww[1:2:end,1:k-1] = wprev[:,1:k-1]
        end
        foo = ClenshawCurtisQuadrature(T,m1)
        ww[:,k] = 2 .* foo.weights
        x = 2 .* foo.nodes .- 1
    end
    m1 = size(ww,1)
    @assert m1>=n
    if roundup
        n = m1
    end
#    ZZ = ClenshawCurtisQuadrature(T,n)
#    x = 2 .*ZZ.nodes .- 1
#    w = 2 .*ZZ.weights
    M = evaluation(x,m1)
    D0 = derivative(T,m1)
    @assert size(M,1)==size(M,2)
    @assert size(D0,1)==size(D0,2)
    D = M*D0/M
    CI = M[:,3:n]
    for k=1:2:size(CI,2)
        CI[:,k] -= M[:,1]
        if k<size(CI,2)
            CI[:,k+1] -= M[:,2]
        end
    end
    L = M[:,1:n-1]
    function interp(y,x)
        sz = size(y)
        y1 = reshape(y,(n,:))
        z = chebfun(M\y1,x)
        if length(sz)==1
            ret = z
        else
            ret = reshape(z,(size(x)...,sz[2:end]...))
        end
#        ret = z[:]
        ret
    end
    n = length(x)
    E = Matrix{T}(I,m1,m1)
    Z = zeros(T,m1,m1)
    Ds = [hcat(E,Z),hcat(D,Z),hcat(Z,E)]
    Rs = []
    for k=1:length(Js)
        k2 = min(Js[k]-1,size(CI,2))
        push!(Rs,hvcat((2,2),CI[:,1:k2],Z[:,1:k2],Z[:,1:k2],L[:,1:k2]))
    end
#    k2 = size(CI,2)
#    push!(Rs,hvcat((2,2),CI[:,1:k2],Z[:,1:k2],Z[:,1:k2],L[:,1:k2]))
    Mesh{T}(x=hcat(x),w=ww,D=Ds,R=Rs,n=n)
end
spectralmesh(n::Integer) = spectralmesh(Float64,n)

"""
    function interp1d(MM::Mesh{T}, y::Array{T,1},x) where {T}

A function to interpolate a solution `y` at some point(s) `x`.

* `MM` the mesh of the solution.
* `y` the solution.
* `x` point(s) at which the solution should be evaluated.
"""
function interp1d(MM::Mesh{T}, y::Array{T,1},x) where {T}
    n = MM.n
    M = evaluation(MM.x,MM.n)
    m1 = size(M,1)
    @assert m1==size(M,2)
    sz = size(y)
    y1 = reshape(y,(m1,:))
    z = chebfun(M\y1,x)
    if length(sz)==1
        ret = z        
    else
        ret = reshape(z,(size(x)...,sz[2:end]...))
    end
    ret
end

"""
    function plot1d(M::Mesh{T},x,y,rest...) where {T}

Plot a solution using `pyplot`.

* `M`: a mesh.
* `x`: x values where the solution should be evaluated and plotted.
* `y`: the solution, to be interpolated at the given `x` values via `interp1d`.
* `rest...` parameters are passed directly to `pyplot.plot`.
"""
function plot1d(M::Mesh{T},x,y,rest...) where {T}
    plot(Float64.(x),Float64.(interp1d(M,y,x)),rest...)
end

"""
    function test1(::Type{T}; 
        maxit=10000, n=5, p=T(1.0), verbose=true, tol=sqrt(eps(T)), 
        show=true, roundup=false) where {T}

Solves a p-Laplace problem in d=1 dimension with the given value of p and 
plot the result.
"""
function test1(::Type{T}; 
        maxit=10000, n=5, p=T(1.0), verbose=true, tol=sqrt(eps(T)), 
        show=true, roundup=false) where {T}
    M = spectralmesh(T,n,roundup=roundup)
    f(x,u,ux,s) = -log(s^(2/p)-ux^2)-2*log(s)
    u0 = M.x[:,1]
    fh = ones(T,size(M.x,1))/2
    c = vcat(fh,ones(T,size(fh)))
    B = barrier(M,(x,y)->f(x...,y...))
    x0 = vcat(u0,2*ones(T,length(u0)))
    SOL = spb(B,c,x0,
        kappa=T(10),maxit=maxit,verbose=verbose,tol=tol)
    if show
        xs = Array(-1:T(0.01):1)
#        ys = M.interp(M.D[1]*SOL.x,xs)
        plot1d(M,xs,M.D[1]*SOL.x)
    end
    SOL
end

"""
    function spectralmesh2d(::Type{T}, n::Integer; roundup=true) where {T}

Create a d=2 dimensional spectral mesh. See `spectralmesh` for details, except
that this is 2-dimensional.
"""
function spectralmesh2d(::Type{T}, n::Integer; roundup=true) where {T}
    M = spectralmesh(T,n;roundup=roundup)
    m1 = size(M.x,1)
    n = M.n
    X = repeat(M.x,1,m1)
    Y = X'
    x = hcat(reshape(X,m1*m1),reshape(Y,m1*m1))
    E = Matrix{T}(I,m1,m1)
    Z = zeros(T,(m1,m1))
    D0 = M.D[2][:,1:m1]
    D = [hcat(kron(E,E),kron(Z,Z)),
         hcat(kron(D0,E),kron(Z,Z)),
         hcat(kron(E,D0),kron(Z,Z)),
         hcat(kron(Z,Z),kron(E,E))]
    R = Array{Array{T,2},1}(undef,length(M.R))
    for k=1:length(M.R)
        U = M.R[k][1:m1,:]
        S = M.R[k][m1+1:end,:]
        R[k] = vcat(kron(U,U),kron(S,S))
    end
    n1 = size(M.w,2)
    w = zeros(T,(m1*m1,n1))
    for k=1:n1
        w[:,k] = kron(M.w[:,k],M.w[:,k])
    end
    Mesh{T}(x=x,w=w,
        D=D,R=R,n=n)
end
spectralmesh2d(n::Integer) = spectralmesh2d(Float64,n)

"""
    function interp2d(MM::Mesh{T},z::Array{T,1},x::Array{T,2}) where {T}

Interpolate a solution `z` at point(s) `x`, given the mesh `MM`. See also
`interp1d`.
"""
function interp2d(MM::Mesh{T},z::Array{T,1},x::Array{T,2}) where {T}
#    n = MM.n
#    M = spectralmesh(T,n)
    m1 = Int(sqrt(size(MM.x,1)))
    M = spectralmesh(m1)
    Z0 = zeros(T,m1)
    function interp0(z::Array{T,1},x::T,y::T)
        ZW = reshape(z,(m1,m1))
        for k=1:m1
            Z0[k] = interp1d(M,ZW[:,k],x)[1]
        end
        interp1d(M,Z0,y)[1]
    end
    function interp1(z::Array{T,1},x::T,y::T)
        ZZ = reshape(z,(m1*m1,:))
        ret1 = zeros(T,size(ZZ,2))
        for k1=1:size(ZZ,2)
            ret1[k1] = interp0(ZZ[:,k1],x,y)
        end
        ret1
    end
    function interp(z::Array{T,1},x::Array{T,2})
        m = Int(size(z,1)/(m1*m1))
        ret2 = zeros(T,(size(x,1),m))
        for k2=1:size(x,1)
            foo = interp1(z,x[k2,1],x[k2,2])
            ret2[k2,:] = foo
        end
        ret2[:]
    end
    interp(z,x)
end

"""
    function plot2d(M::Mesh{T},x,y,z::Array{T,1};rest...) where {T}

Plot a 2d solution.

* `M` a 2d mesh.
* `x`, `y` should be ranges like -1:0.01:1.
* `z` the solution to plot.
"""
function plot2d(M::Mesh{T},x,y,z::Array{T,1};rest...) where {T}
    X = repeat(x,1,length(y))
    Y = repeat(y,1,length(x))'
    sz = (length(x),length(y))
    Z = reshape(interp2d(M,z,hcat(X[:],Y[:])),(length(x),length(y)))
    gcf().add_subplot(projection="3d")
    dx = maximum(x)-minimum(x)
    dy = maximum(y)-minimum(y)
    lw = max(dx,dy)*0.002
    plot_surface(Float64.(x), Float64.(y), Float64.(Z); rcount=50, ccount=50, antialiased=false, edgecolor=:black, linewidth=Float64(lw), rest...)
#        plot_wireframe(x,y,Z; rcount=10, ccount=10, color=:white, edgecolor=:black)
    end

"""
    function test2(::Type{T}; g = (x,y)->x.^2+y.^2, 
        ff = (x,y)->0.5*ones(T,size(x)), maxit=10000, n=5, p=T(1.0),
        verbose=true, show=true, roundup=false) where {T}

Solves a p-Laplace problem in d=1 dimension with the given value of p and 
plot the result.
"""
function test2(::Type{T}; g = (x,y)->x.^2+y.^2, 
        ff = (x,y)->0.5*ones(T,size(x)), maxit=10000, n=5, p=T(1.0),
        verbose=true, show=true, roundup=false) where {T}
    M = spectralmesh2d(T,n,roundup=roundup)
    f(x,y,u,ux,uy,s) = -log(s^(2/p)-ux^2-uy^2)-2*log(s)
    u0 = g(M.x[:,1],M.x[:,2])
    fh = ff(M.x[:,1],M.x[:,2])
    c = vcat(fh,ones(T,size(fh)))
    x0 = vcat(u0,(3^p)*ones(T,length(u0)))
    B = barrier(M,(x,y)->f(x...,y...))
    SOL = spb(B,c,x0,
        kappa=T(10),maxit=maxit,verbose=verbose)
    if show
        plot2d(M,-1:T(0.01):1,-1:T(0.01):1,M.D[1]*SOL.x;cmap=:jet)
    end
    SOL
end



function _precompile()
    test1(Float64)
    test1(BigFloat)
    test2(Float64)
    test2(BigFloat)
end

precompile(_precompile,())
end
