# Adapted from the fast_interpn project by David Stein
# https://github.com/dbstein/fast_interpn
# This file is licensed under Apache 2.0 license
import numpy as np
import numba
from numba.typed import List


def fast_interp_warmup():
    x = np.linspace(0,1,8)
    data = x[:,None,None]*x[None,:,None]*x[None,None,:]
    y = np.random.uniform(size=(2,2))
    _ = interp3d([0]*3,[1]*3,[1]*3,data,k=3)(y,y,y)


################################################################################
# variables to control when we switch between serial / parallel versions

serial_cutoffs = [0, 2000, 400, 100]
def set_serial_cutoffs(dimension, cutoff):
    serial_cutoffs[dimension] = cutoff

################################################################################
# utilities to enable serial / parallel compilation of same function

def sjit(func):
    return numba.njit(func, parallel=False, cache=True)
def pjit(func):
    return numba.njit(func, parallel=True, cache=True)

################################################################################
# utility to allow construction of TypedList with Float/Int types (always promoted to float)

def FloatList(l):
    return List([float(lh) for lh in l])
def IntList(l):
    return List([int(lh) for lh in l])
def BoolList(l):
    return List([bool(lh) for lh in l])

################################################################################
# 1D Extrapolation Routines

def _extrapolate1d_x(f, k, o):
    for ix in range(o):
        il = o-ix-1
        ih = f.shape[0]-(o-ix)
        if k == 1:
            f[il] = 2*f[il+1] - 1*f[il+2]
            f[ih] = 2*f[ih-1] - 1*f[ih-2]
        if k == 3:
            f[il] = 4*f[il+1] - 6*f[il+2] + 4*f[il+3] - f[il+4]
            f[ih] = 4*f[ih-1] - 6*f[ih-2] + 4*f[ih-3] - f[ih-4]
        if k == 5:
            f[il] = 6*f[il+1]-15*f[il+2]+20*f[il+3]-15*f[il+4]+6*f[il+5]-f[il+6]
            f[ih] = 6*f[ih-1]-15*f[ih-2]+20*f[ih-3]-15*f[ih-4]+6*f[ih-5]-f[ih-6]
        if k == 7:
            f[il] = 8*f[il+1]-28*f[il+2]+56*f[il+3]-70*f[il+4]+56*f[il+5]-28*f[il+6]+8*f[il+7]-f[il+8]
            f[ih] = 8*f[ih-1]-28*f[ih-2]+56*f[ih-3]-70*f[ih-4]+56*f[ih-5]-28*f[ih-6]+8*f[ih-7]-f[ih-8]
        if k == 9:
            f[il] = 10*f[il+1]-45*f[il+2]+120*f[il+3]-210*f[il+4]+252*f[il+5]-210*f[il+6]+120*f[il+7]-45*f[il+8]+10*f[il+9]-f[il+10]
            f[ih] = 10*f[ih-1]-45*f[ih-2]+120*f[ih-3]-210*f[ih-4]+252*f[ih-5]-210*f[ih-6]+120*f[ih-7]-45*f[ih-8]+10*f[ih-9]-f[ih-10]
def _extrapolate1d_y(f, k, o):
    for ix in range(o):
        il = o-ix-1
        ih = f.shape[1]-(o-ix)
        if k == 1:
            f[:,il] = 2*f[:,il+1] - 1*f[:,il+2]
            f[:,ih] = 2*f[:,ih-1] - 1*f[:,ih-2]
        if k == 3:
            f[:,il] = 4*f[:,il+1] - 6*f[:,il+2] + 4*f[:,il+3] - f[:,il+4]
            f[:,ih] = 4*f[:,ih-1] - 6*f[:,ih-2] + 4*f[:,ih-3] - f[:,ih-4]
        if k == 5:
            f[:,il] = 6*f[:,il+1]-15*f[:,il+2]+20*f[:,il+3]-15*f[:,il+4]+6*f[:,il+5]-f[:,il+6]
            f[:,ih] = 6*f[:,ih-1]-15*f[:,ih-2]+20*f[:,ih-3]-15*f[:,ih-4]+6*f[:,ih-5]-f[:,ih-6]
        if k == 7:
            f[:,il] = 8*f[:,il+1]-28*f[:,il+2]+56*f[:,il+3]-70*f[:,il+4]+56*f[:,il+5]-28*f[:,il+6]+8*f[:,il+7]-f[:,il+8]
            f[:,ih] = 8*f[:,ih-1]-28*f[:,ih-2]+56*f[:,ih-3]-70*f[:,ih-4]+56*f[:,ih-5]-28*f[:,ih-6]+8*f[:,ih-7]-f[:,ih-8]
        if k == 9:
            f[:,il] = 10*f[:,il+1]-45*f[:,il+2]+120*f[:,il+3]-210*f[:,il+4]+252*f[:,il+5]-210*f[:,il+6]+120*f[:,il+7]-45*f[:,il+8]+10*f[:,il+9]-f[:,il+10]
            f[:,ih] = 10*f[:,ih-1]-45*f[:,ih-2]+120*f[:,ih-3]-210*f[:,ih-4]+252*f[:,ih-5]-210*f[:,ih-6]+120*f[:,ih-7]-45*f[:,ih-8]+10*f[:,ih-9]-f[:,ih-10]
def _extrapolate1d_z(f, k, o):
    for ix in range(o):
        il = o-ix-1
        ih = f.shape[2]-(o-ix)
        if k == 1:
            f[:,:,il] = 2*f[:,:,il+1] - 1*f[:,:,il+2]
            f[:,:,ih] = 2*f[:,:,ih-1] - 1*f[:,:,ih-2]
        if k == 3:
            f[:,:,il] = 4*f[:,:,il+1] - 6*f[:,:,il+2] + 4*f[:,:,il+3] - f[:,:,il+4]
            f[:,:,ih] = 4*f[:,:,ih-1] - 6*f[:,:,ih-2] + 4*f[:,:,ih-3] - f[:,:,ih-4]
        if k == 5:
            f[:,:,il] = 6*f[:,:,il+1]-15*f[:,:,il+2]+20*f[:,:,il+3]-15*f[:,:,il+4]+6*f[:,:,il+5]-f[:,:,il+6]
            f[:,:,ih] = 6*f[:,:,ih-1]-15*f[:,:,ih-2]+20*f[:,:,ih-3]-15*f[:,:,ih-4]+6*f[:,:,ih-5]-f[:,:,ih-6]
        if k == 7:
            f[:,:,il] = 8*f[:,:,il+1]-28*f[:,:,il+2]+56*f[:,:,il+3]-70*f[:,:,il+4]+56*f[:,:,il+5]-28*f[:,:,il+6]+8*f[:,:,il+7]-f[:,:,il+8]
            f[:,:,ih] = 8*f[:,:,ih-1]-28*f[:,:,ih-2]+56*f[:,:,ih-3]-70*f[:,:,ih-4]+56*f[:,:,ih-5]-28*f[:,:,ih-6]+8*f[:,:,ih-7]-f[:,:,ih-8]
        if k == 9:
            f[:,:,il] = 10*f[:,:,il+1]-45*f[:,:,il+2]+120*f[:,:,il+3]-210*f[:,:,il+4]+252*f[:,:,il+5]-210*f[:,:,il+6]+120*f[:,:,il+7]-45*f[:,:,il+8]+10*f[:,:,il+9]-f[:,:,il+10]
            f[:,:,ih] = 10*f[:,:,ih-1]-45*f[:,:,ih-2]+120*f[:,:,ih-3]-210*f[:,:,ih-4]+252*f[:,:,ih-5]-210*f[:,:,ih-6]+120*f[:,:,ih-7]-45*f[:,:,ih-8]+10*f[:,:,ih-9]-f[:,:,ih-10]

################################################################################
# One dimensional routines

class interp1d(object):
    def __init__(self, a, b, h, f, k=3, p=False, c=True, e=0):
        """
        a, b: the lower and upper bounds of the interpolation region
        h:    the grid-spacing at which f is given
        f:    data to be interpolated
        k:    order of local taylor expansions (int, 1, 3, or 5)
        p:    whether the dimension is taken to be periodic
        c:    whether the array should be padded to allow accurate close eval
        e:    extrapolation distance, how far to allow extrap, in units of h
                (needs to be an integer)
        if p is True, then f is assumed to given on:
            [a, b)
        if p is False, f is assumed to be given on:
            [a, b]
        For periodic interpolation (p = True)
            this will interpolate accurately for any x
            c is ignored
            e is ignored
        For non-periodic interpolation (p = False)
            if c is True the function is padded to allow accurate eval on:
                [a-e*h, b+e*h]
                (extrapolation is done on [a-e*h, a] and [b, b+e*h], be careful!)
            if c is False, the function evaluates accurately on:
                [a,    b   ] for k = 1
                [a+h,  b-h ] for k = 3
                [a+2h, b-2h] for k = 5
                e is ignored
            c = True requires the allocation of a padded data array, as well
                as a memory copy from f to the padded array and some
                time computing function extrapolations, this setup time is
                quite small and fine when interpolating to many points but
                is significant when interpolating to only a few points
            right now there is no bounds checking; this will probably segfault
            if you provide values outside of the safe interpolation region...
        """
        if k not in [1, 3, 5, 7, 9]:
            raise Exception('k must be 1, 3, 5, 7, or 9')
        self.a = a
        self.b = b
        self.h = h
        self.f = f
        self.k = k
        self.p = p
        self.c = c
        self.e = e
        self.n = f.shape[0]
        self.dtype = f.dtype
        self._f, self._o = _extrapolate1d(f, k, p, c, e)
        self.lb, self.ub = _compute_bounds1(a, b, h, p, c, e, k)
    def __call__(self, xout, fout=None):
        """
        Interpolate to xout
        xout must be a float or a ndarray of floats
        if xout.size > serial_cutoff, use parallel version
        """
        if isinstance(xout, np.ndarray):
            if xout.size > serial_cutoffs[1]:
                func = PAR_INTERP_1D[self.k]
            else:
                func = SER_INTERP_1D[self.k]
            m = int(np.prod(xout.shape))
            copy_made = False
            if fout is None:
                _out = np.empty(m, dtype=self.dtype)
            else:
                _out = fout.ravel()
                if _out.base is None:
                    copy_made = True
            _xout = xout.ravel()
            func(self._f, _xout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            if copy_made:
                fout[:] = _out
            return _out.reshape(xout.shape)
        else:
            func = SER_INTERP_1D[self.k]
            _xout = np.array([xout],)
            _out = np.empty(1)
            func(self._f, _xout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            return _out[0]

# interpolation routines
def _interp1d_k1(f, xout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb), ub)
        xx = xr - a
        ix = int(xx//h)
        ratx = xx/h - (ix+0.5)
        asx = np.empty(2)
        asx[0] = 0.5 - ratx
        asx[1] = 0.5 + ratx
        ix += o
        fout[mi] = 0.0
        for i in range(2):
            ixi = (ix + i) % n if p else ix + i
            fout[mi] += f[ixi]*asx[i]
def _interp1d_k3(f, xout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb), ub)
        xx = xr - a
        ix = int(xx//h)
        ratx = xx/h - (ix+0.5)
        asx = np.empty(4)
        asx[0] = -1/16 + ratx*( 1/24 + ratx*( 1/4 - ratx/6))
        asx[1] =  9/16 + ratx*( -9/8 + ratx*(-1/4 + ratx/2))
        asx[2] =  9/16 + ratx*(  9/8 + ratx*(-1/4 - ratx/2))
        asx[3] = -1/16 + ratx*(-1/24 + ratx*( 1/4 + ratx/6))
        ix += o-1
        fout[mi] = 0.0
        for i in range(4):
            ixi = (ix + i) % n if p else ix + i
            fout[mi] += f[ixi]*asx[i]
def _interp1d_k5(f, xout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb), ub)
        xx = xr - a
        ix = int(xx//h)
        ratx = xx/h - (ix+0.5)
        asx = np.empty(6)
        asx[0] =   3/256 + ratx*(   -9/1920 + ratx*( -5/48/2 + ratx*(  1/8/6 + ratx*( 1/2/24 -  1/8/120*ratx))))
        asx[1] = -25/256 + ratx*(  125/1920 + ratx*( 39/48/2 + ratx*(-13/8/6 + ratx*(-3/2/24 +  5/8/120*ratx))))
        asx[2] = 150/256 + ratx*(-2250/1920 + ratx*(-34/48/2 + ratx*( 34/8/6 + ratx*( 2/2/24 - 10/8/120*ratx))))
        asx[3] = 150/256 + ratx*( 2250/1920 + ratx*(-34/48/2 + ratx*(-34/8/6 + ratx*( 2/2/24 + 10/8/120*ratx))))
        asx[4] = -25/256 + ratx*( -125/1920 + ratx*( 39/48/2 + ratx*( 13/8/6 + ratx*(-3/2/24 -  5/8/120*ratx))))
        asx[5] =   3/256 + ratx*(    9/1920 + ratx*( -5/48/2 + ratx*( -1/8/6 + ratx*( 1/2/24 +  1/8/120*ratx))))
        ix += o-2
        fout[mi] = 0.0
        for i in range(6):
            ixi = (ix + i) % n if p else ix + i
            fout[mi] += f[ixi]*asx[i]
def _interp1d_k7(f, xout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb), ub)
        xx = xr - a
        ix = int(xx//h)
        ratx = xx/h - (ix+0.5)
        asx = np.empty(8)
        asx[0] =   -5/2048 + ratx*(     75/107520 + ratx*(  259/11520/2 + ratx*(  -37/1920/6 + ratx*(  -7/48/24 + ratx*(   5/24/120 + ratx*( 1/2/720 -  1/5040*ratx))))))
        asx[1] =   49/2048 + ratx*(  -1029/107520 + ratx*(-2495/11520/2 + ratx*(  499/1920/6 + ratx*(  59/48/24 + ratx*( -59/24/120 + ratx*(-5/2/720 +  7/5040*ratx))))))
        asx[2] = -245/2048 + ratx*(   8575/107520 + ratx*(11691/11520/2 + ratx*(-3897/1920/6 + ratx*(-135/48/24 + ratx*( 225/24/120 + ratx*( 9/2/720 - 21/5040*ratx))))))
        asx[3] = 1225/2048 + ratx*(-128625/107520 + ratx*(-9455/11520/2 + ratx*( 9455/1920/6 + ratx*(  83/48/24 + ratx*(-415/24/120 + ratx*(-5/2/720 + 35/5040*ratx))))))
        asx[4] = 1225/2048 + ratx*( 128625/107520 + ratx*(-9455/11520/2 + ratx*(-9455/1920/6 + ratx*(  83/48/24 + ratx*( 415/24/120 + ratx*(-5/2/720 - 35/5040*ratx))))))
        asx[5] = -245/2048 + ratx*(  -8575/107520 + ratx*(11691/11520/2 + ratx*( 3897/1920/6 + ratx*(-135/48/24 + ratx*(-225/24/120 + ratx*( 9/2/720 + 21/5040*ratx))))))
        asx[6] =   49/2048 + ratx*(   1029/107520 + ratx*(-2495/11520/2 + ratx*( -499/1920/6 + ratx*(  59/48/24 + ratx*(  59/24/120 + ratx*(-5/2/720 -  7/5040*ratx))))))
        asx[7] =   -5/2048 + ratx*(    -75/107520 + ratx*(  259/11520/2 + ratx*(   37/1920/6 + ratx*(  -7/48/24 + ratx*(  -5/24/120 + ratx*( 1/2/720 +  1/5040*ratx))))))
        ix += o-3
        fout[mi] = 0.0
        for i in range(8):
            ixi = (ix + i) % n if p else ix + i
            fout[mi] += f[ixi]*asx[i]
def _interp1d_k9(f, xout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb), ub)
        xx = xr - a
        ix = int(xx//h)
        ratx = xx/h - (ix+0.5)
        asx = np.empty(10)
        asx[0] =    35/65536 + ratx*(    -1225/10321920 + ratx*(  -3229/645120/2 + ratx*(    3229/967680/6 + ratx*(   141/3840/24 + ratx*(   -47/1152/120 + ratx*(  -3/16/720 + ratx*(    7/24/5040 + ratx*(  1/2/40320 -   1/362880*ratx))))))))
        asx[1] =  -405/65536 + ratx*(    18225/10321920 + ratx*(  37107/645120/2 + ratx*(  -47709/967680/6 + ratx*( -1547/3840/24 + ratx*(   663/1152/120 + ratx*(  29/16/720 + ratx*(  -87/24/5040 + ratx*( -7/2/40320 +   9/362880*ratx))))))))
        asx[2] =  2268/65536 + ratx*(  -142884/10321920 + ratx*(-204300/645120/2 + ratx*(  367740/967680/6 + ratx*(  7540/3840/24 + ratx*( -4524/1152/120 + ratx*(-100/16/720 + ratx*(  420/24/5040 + ratx*( 20/2/40320 -  36/362880*ratx))))))))
        asx[3] = -8820/65536 + ratx*(   926100/10321920 + ratx*( 745108/645120/2 + ratx*(-2235324/967680/6 + ratx*(-14748/3840/24 + ratx*( 14748/1152/120 + ratx*( 156/16/720 + ratx*(-1092/24/5040 + ratx*(-28/2/40320 +  84/362880*ratx))))))))
        asx[4] = 39690/65536 + ratx*(-12502350/10321920 + ratx*(-574686/645120/2 + ratx*( 5172174/967680/6 + ratx*(  8614/3840/24 + ratx*(-25842/1152/120 + ratx*( -82/16/720 + ratx*( 1722/24/5040 + ratx*( 14/2/40320 - 126/362880*ratx))))))))
        asx[5] = 39690/65536 + ratx*( 12502350/10321920 + ratx*(-574686/645120/2 + ratx*(-5172174/967680/6 + ratx*(  8614/3840/24 + ratx*( 25842/1152/120 + ratx*( -82/16/720 + ratx*(-1722/24/5040 + ratx*( 14/2/40320 + 126/362880*ratx))))))))
        asx[6] = -8820/65536 + ratx*(  -926100/10321920 + ratx*( 745108/645120/2 + ratx*( 2235324/967680/6 + ratx*(-14748/3840/24 + ratx*(-14748/1152/120 + ratx*( 156/16/720 + ratx*( 1092/24/5040 + ratx*(-28/2/40320 -  84/362880*ratx))))))))
        asx[7] =  2268/65536 + ratx*(   142884/10321920 + ratx*(-204300/645120/2 + ratx*( -367740/967680/6 + ratx*(  7540/3840/24 + ratx*(  4524/1152/120 + ratx*(-100/16/720 + ratx*( -420/24/5040 + ratx*( 20/2/40320 +  36/362880*ratx))))))))
        asx[8] =  -405/65536 + ratx*(   -18225/10321920 + ratx*(  37107/645120/2 + ratx*(   47709/967680/6 + ratx*( -1547/3840/24 + ratx*(  -663/1152/120 + ratx*(  29/16/720 + ratx*(   87/24/5040 + ratx*( -7/2/40320 -   9/362880*ratx))))))))
        asx[9] =    35/65536 + ratx*(     1225/10321920 + ratx*(  -3229/645120/2 + ratx*(   -3229/967680/6 + ratx*(   141/3840/24 + ratx*(    47/1152/120 + ratx*(  -3/16/720 + ratx*(   -7/24/5040 + ratx*(  1/2/40320 +   1/362880*ratx))))))))
        ix += o-4
        fout[mi] = 0.0
        for i in range(10):
            ixi = (ix + i) % n if p else ix + i
            fout[mi] += f[ixi]*asx[i]

_s_interp1d_k1 = sjit(_interp1d_k1)
_s_interp1d_k3 = sjit(_interp1d_k3)
_s_interp1d_k5 = sjit(_interp1d_k5)
_s_interp1d_k7 = sjit(_interp1d_k7)
_s_interp1d_k9 = sjit(_interp1d_k9)
_p_interp1d_k1 = pjit(_interp1d_k1)
_p_interp1d_k3 = pjit(_interp1d_k3)
_p_interp1d_k5 = pjit(_interp1d_k5)
_p_interp1d_k7 = pjit(_interp1d_k7)
_p_interp1d_k9 = pjit(_interp1d_k9)

SER_INTERP_1D = [None, _s_interp1d_k1, None, _s_interp1d_k3, None, _s_interp1d_k5, None, _s_interp1d_k7, None, _s_interp1d_k9]
PAR_INTERP_1D = [None, _p_interp1d_k1, None, _p_interp1d_k3, None, _p_interp1d_k5, None, _p_interp1d_k7, None, _p_interp1d_k9]

# extrapolation routines
def _extrapolate1d(f, k, p, c, e):
    pad = (not p) and c
    if pad:
        o = (k//2)+e
        fb = np.empty(f.shape[0]+2*o, dtype=f.dtype)
        _fill1(f, fb, o)
        _extrapolate1d_x(fb, k, o)
        return fb, o
    else:
        return f, 0
    return fb
def _fill1(f, fb, o):
    fb[o:o+f.shape[0]] = f
def _compute_bounds1(a, b, h, p, c, e, k):
    if p:
        return -1e100, 1e100
    elif not c:
        d = h*(k//2)
        return a+d, b-d
    else:
        d = e*h
        u = b+d
        u -= u*1e-15 # the routines can fail when we exactly hit the right endpoint, this protects against that
        return a-d, u

################################################################################
# Two dimensional routines

class interp2d(object):
    def __init__(self, a, b, h, f, k=3, p=[False]*2, c=[True]*2, e=[0]*2):
        """
        See the documentation for interp1d
        this function is the same, except that a, b, h, p, c, and e
        should be lists or tuples of length 2 giving the values for each
        dimension
        the function behaves as in the 1d case, except that of course padding
        is required if padding is requested in any dimension
        """
        if k not in [1, 3, 5, 7, 9]:
            raise Exception('k must be 1, 3, 5, 7, or 9')
        self.a = FloatList(a)
        self.b = FloatList(b)
        self.h = FloatList(h)
        self.f = f
        self.k = k
        self.p = BoolList(p)
        self.c = BoolList(c)
        self.e = IntList(e)
        self.n = IntList(f.shape)
        self.dtype = f.dtype
        self._f, _o = _extrapolate2d(f, k, p, c, e)
        self._o = IntList(_o)
        lb, ub = _compute_bounds(a, b, h, p, c, e, k)
        self.lb = FloatList(lb)
        self.ub = FloatList(ub)
    def __call__(self, xout, yout, fout=None):
        """
        Interpolate to xout
        For 1-D interpolation, xout must be a float
            or a ndarray of floats
        """
        if isinstance(xout, np.ndarray):
            if xout.size > serial_cutoffs[2]:
                func = PAR_INTERP_2D[self.k]
            else:
                func = SER_INTERP_2D[self.k]
            m = int(np.prod(xout.shape))
            copy_made = False
            if fout is None:
                _out = np.empty(m, dtype=self.dtype)
            else:
                _out = fout.ravel()
                if _out.base is None:
                    copy_made = True
            _xout = xout.ravel()
            _yout = yout.ravel()
            func(self._f, _xout, _yout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            if copy_made:
                fout[:] = _out
            return _out.reshape(xout.shape)
        else:
            func = SER_INTERP_2D[self.k]
            _xout = np.array([xout],)
            _yout = np.array([yout],)
            _out = np.empty(1)
            func(self._f, _xout, _yout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            return _out[0]

# interpolation routines
def _interp2d_k1(f, xout, yout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        xx = xr - a[0]
        yy = yr - a[1]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        asx = np.empty(2)
        asy = np.empty(2)
        asx[0] = 0.5 - ratx
        asx[1] = 0.5 + ratx
        asy[0] = 0.5 - raty
        asy[1] = 0.5 + raty
        ix += o[0]
        iy += o[1]
        fout[mi] = 0.0
        for i in range(2):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(2):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                fout[mi] += f[ixi,iyj]*asx[i]*asy[j]
def _interp2d_k3(f, xout, yout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        xx = xr - a[0]
        yy = yr - a[1]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        asx = np.empty(4)
        asy = np.empty(4)
        asx[0] = -1/16 + ratx*( 1/24 + ratx*( 1/4 - ratx/6))
        asx[1] =  9/16 + ratx*( -9/8 + ratx*(-1/4 + ratx/2))
        asx[2] =  9/16 + ratx*(  9/8 + ratx*(-1/4 - ratx/2))
        asx[3] = -1/16 + ratx*(-1/24 + ratx*( 1/4 + ratx/6))
        asy[0] = -1/16 + raty*( 1/24 + raty*( 1/4 - raty/6))
        asy[1] =  9/16 + raty*( -9/8 + raty*(-1/4 + raty/2))
        asy[2] =  9/16 + raty*(  9/8 + raty*(-1/4 - raty/2))
        asy[3] = -1/16 + raty*(-1/24 + raty*( 1/4 + raty/6))
        ix += o[0]-1
        iy += o[1]-1
        fout[mi] = 0.0
        for i in range(4):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(4):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                fout[mi] += f[ixi,iyj]*asx[i]*asy[j]
def _interp2d_k5(f, xout, yout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        xx = xr - a[0]
        yy = yr - a[1]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        asx = np.empty(6)
        asy = np.empty(6)
        asx[0] =   3/256 + ratx*(   -9/1920 + ratx*( -5/48/2 + ratx*(  1/8/6 + ratx*( 1/2/24 -  1/8/120*ratx))))
        asx[1] = -25/256 + ratx*(  125/1920 + ratx*( 39/48/2 + ratx*(-13/8/6 + ratx*(-3/2/24 +  5/8/120*ratx))))
        asx[2] = 150/256 + ratx*(-2250/1920 + ratx*(-34/48/2 + ratx*( 34/8/6 + ratx*( 2/2/24 - 10/8/120*ratx))))
        asx[3] = 150/256 + ratx*( 2250/1920 + ratx*(-34/48/2 + ratx*(-34/8/6 + ratx*( 2/2/24 + 10/8/120*ratx))))
        asx[4] = -25/256 + ratx*( -125/1920 + ratx*( 39/48/2 + ratx*( 13/8/6 + ratx*(-3/2/24 -  5/8/120*ratx))))
        asx[5] =   3/256 + ratx*(    9/1920 + ratx*( -5/48/2 + ratx*( -1/8/6 + ratx*( 1/2/24 +  1/8/120*ratx))))
        asy[0] =   3/256 + raty*(   -9/1920 + raty*( -5/48/2 + raty*(  1/8/6 + raty*( 1/2/24 -  1/8/120*raty))))
        asy[1] = -25/256 + raty*(  125/1920 + raty*( 39/48/2 + raty*(-13/8/6 + raty*(-3/2/24 +  5/8/120*raty))))
        asy[2] = 150/256 + raty*(-2250/1920 + raty*(-34/48/2 + raty*( 34/8/6 + raty*( 2/2/24 - 10/8/120*raty))))
        asy[3] = 150/256 + raty*( 2250/1920 + raty*(-34/48/2 + raty*(-34/8/6 + raty*( 2/2/24 + 10/8/120*raty))))
        asy[4] = -25/256 + raty*( -125/1920 + raty*( 39/48/2 + raty*( 13/8/6 + raty*(-3/2/24 -  5/8/120*raty))))
        asy[5] =   3/256 + raty*(    9/1920 + raty*( -5/48/2 + raty*( -1/8/6 + raty*( 1/2/24 +  1/8/120*raty))))
        ix += o[0]-2
        iy += o[1]-2
        fout[mi] = 0.0
        for i in range(6):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(6):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                fout[mi] += f[ixi,iyj]*asx[i]*asy[j]
def _interp2d_k7(f, xout, yout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        xx = xr - a[0]
        yy = yr - a[1]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        asx = np.empty(8)
        asy = np.empty(8)
        asx[0] =   -5/2048 + ratx*(     75/107520 + ratx*(  259/11520/2 + ratx*(  -37/1920/6 + ratx*(  -7/48/24 + ratx*(   5/24/120 + ratx*( 1/2/720 -  1/5040*ratx))))))
        asx[1] =   49/2048 + ratx*(  -1029/107520 + ratx*(-2495/11520/2 + ratx*(  499/1920/6 + ratx*(  59/48/24 + ratx*( -59/24/120 + ratx*(-5/2/720 +  7/5040*ratx))))))
        asx[2] = -245/2048 + ratx*(   8575/107520 + ratx*(11691/11520/2 + ratx*(-3897/1920/6 + ratx*(-135/48/24 + ratx*( 225/24/120 + ratx*( 9/2/720 - 21/5040*ratx))))))
        asx[3] = 1225/2048 + ratx*(-128625/107520 + ratx*(-9455/11520/2 + ratx*( 9455/1920/6 + ratx*(  83/48/24 + ratx*(-415/24/120 + ratx*(-5/2/720 + 35/5040*ratx))))))
        asx[4] = 1225/2048 + ratx*( 128625/107520 + ratx*(-9455/11520/2 + ratx*(-9455/1920/6 + ratx*(  83/48/24 + ratx*( 415/24/120 + ratx*(-5/2/720 - 35/5040*ratx))))))
        asx[5] = -245/2048 + ratx*(  -8575/107520 + ratx*(11691/11520/2 + ratx*( 3897/1920/6 + ratx*(-135/48/24 + ratx*(-225/24/120 + ratx*( 9/2/720 + 21/5040*ratx))))))
        asx[6] =   49/2048 + ratx*(   1029/107520 + ratx*(-2495/11520/2 + ratx*( -499/1920/6 + ratx*(  59/48/24 + ratx*(  59/24/120 + ratx*(-5/2/720 -  7/5040*ratx))))))
        asx[7] =   -5/2048 + ratx*(    -75/107520 + ratx*(  259/11520/2 + ratx*(   37/1920/6 + ratx*(  -7/48/24 + ratx*(  -5/24/120 + ratx*( 1/2/720 +  1/5040*ratx))))))
        asy[0] =   -5/2048 + raty*(     75/107520 + raty*(  259/11520/2 + raty*(  -37/1920/6 + raty*(  -7/48/24 + raty*(   5/24/120 + raty*( 1/2/720 -  1/5040*raty))))))
        asy[1] =   49/2048 + raty*(  -1029/107520 + raty*(-2495/11520/2 + raty*(  499/1920/6 + raty*(  59/48/24 + raty*( -59/24/120 + raty*(-5/2/720 +  7/5040*raty))))))
        asy[2] = -245/2048 + raty*(   8575/107520 + raty*(11691/11520/2 + raty*(-3897/1920/6 + raty*(-135/48/24 + raty*( 225/24/120 + raty*( 9/2/720 - 21/5040*raty))))))
        asy[3] = 1225/2048 + raty*(-128625/107520 + raty*(-9455/11520/2 + raty*( 9455/1920/6 + raty*(  83/48/24 + raty*(-415/24/120 + raty*(-5/2/720 + 35/5040*raty))))))
        asy[4] = 1225/2048 + raty*( 128625/107520 + raty*(-9455/11520/2 + raty*(-9455/1920/6 + raty*(  83/48/24 + raty*( 415/24/120 + raty*(-5/2/720 - 35/5040*raty))))))
        asy[5] = -245/2048 + raty*(  -8575/107520 + raty*(11691/11520/2 + raty*( 3897/1920/6 + raty*(-135/48/24 + raty*(-225/24/120 + raty*( 9/2/720 + 21/5040*raty))))))
        asy[6] =   49/2048 + raty*(   1029/107520 + raty*(-2495/11520/2 + raty*( -499/1920/6 + raty*(  59/48/24 + raty*(  59/24/120 + raty*(-5/2/720 -  7/5040*raty))))))
        asy[7] =   -5/2048 + raty*(    -75/107520 + raty*(  259/11520/2 + raty*(   37/1920/6 + raty*(  -7/48/24 + raty*(  -5/24/120 + raty*( 1/2/720 +  1/5040*raty))))))
        ix += o[0]-3
        iy += o[1]-3
        fout[mi] = 0.0
        for i in range(8):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(8):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                fout[mi] += f[ixi,iyj]*asx[i]*asy[j]
def _interp2d_k9(f, xout, yout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        xx = xr - a[0]
        yy = yr - a[1]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        asx = np.empty(10)
        asy = np.empty(10)
        asx[0] =    35/65536 + ratx*(    -1225/10321920 + ratx*(  -3229/645120/2 + ratx*(    3229/967680/6 + ratx*(   141/3840/24 + ratx*(   -47/1152/120 + ratx*(  -3/16/720 + ratx*(    7/24/5040 + ratx*(  1/2/40320 -   1/362880*ratx))))))))
        asx[1] =  -405/65536 + ratx*(    18225/10321920 + ratx*(  37107/645120/2 + ratx*(  -47709/967680/6 + ratx*( -1547/3840/24 + ratx*(   663/1152/120 + ratx*(  29/16/720 + ratx*(  -87/24/5040 + ratx*( -7/2/40320 +   9/362880*ratx))))))))
        asx[2] =  2268/65536 + ratx*(  -142884/10321920 + ratx*(-204300/645120/2 + ratx*(  367740/967680/6 + ratx*(  7540/3840/24 + ratx*( -4524/1152/120 + ratx*(-100/16/720 + ratx*(  420/24/5040 + ratx*( 20/2/40320 -  36/362880*ratx))))))))
        asx[3] = -8820/65536 + ratx*(   926100/10321920 + ratx*( 745108/645120/2 + ratx*(-2235324/967680/6 + ratx*(-14748/3840/24 + ratx*( 14748/1152/120 + ratx*( 156/16/720 + ratx*(-1092/24/5040 + ratx*(-28/2/40320 +  84/362880*ratx))))))))
        asx[4] = 39690/65536 + ratx*(-12502350/10321920 + ratx*(-574686/645120/2 + ratx*( 5172174/967680/6 + ratx*(  8614/3840/24 + ratx*(-25842/1152/120 + ratx*( -82/16/720 + ratx*( 1722/24/5040 + ratx*( 14/2/40320 - 126/362880*ratx))))))))
        asx[5] = 39690/65536 + ratx*( 12502350/10321920 + ratx*(-574686/645120/2 + ratx*(-5172174/967680/6 + ratx*(  8614/3840/24 + ratx*( 25842/1152/120 + ratx*( -82/16/720 + ratx*(-1722/24/5040 + ratx*( 14/2/40320 + 126/362880*ratx))))))))
        asx[6] = -8820/65536 + ratx*(  -926100/10321920 + ratx*( 745108/645120/2 + ratx*( 2235324/967680/6 + ratx*(-14748/3840/24 + ratx*(-14748/1152/120 + ratx*( 156/16/720 + ratx*( 1092/24/5040 + ratx*(-28/2/40320 -  84/362880*ratx))))))))
        asx[7] =  2268/65536 + ratx*(   142884/10321920 + ratx*(-204300/645120/2 + ratx*( -367740/967680/6 + ratx*(  7540/3840/24 + ratx*(  4524/1152/120 + ratx*(-100/16/720 + ratx*( -420/24/5040 + ratx*( 20/2/40320 +  36/362880*ratx))))))))
        asx[8] =  -405/65536 + ratx*(   -18225/10321920 + ratx*(  37107/645120/2 + ratx*(   47709/967680/6 + ratx*( -1547/3840/24 + ratx*(  -663/1152/120 + ratx*(  29/16/720 + ratx*(   87/24/5040 + ratx*( -7/2/40320 -   9/362880*ratx))))))))
        asx[9] =    35/65536 + ratx*(     1225/10321920 + ratx*(  -3229/645120/2 + ratx*(   -3229/967680/6 + ratx*(   141/3840/24 + ratx*(    47/1152/120 + ratx*(  -3/16/720 + ratx*(   -7/24/5040 + ratx*(  1/2/40320 +   1/362880*ratx))))))))
        asy[0] =    35/65536 + raty*(    -1225/10321920 + raty*(  -3229/645120/2 + raty*(    3229/967680/6 + raty*(   141/3840/24 + raty*(   -47/1152/120 + raty*(  -3/16/720 + raty*(    7/24/5040 + raty*(  1/2/40320 -   1/362880*raty))))))))
        asy[1] =  -405/65536 + raty*(    18225/10321920 + raty*(  37107/645120/2 + raty*(  -47709/967680/6 + raty*( -1547/3840/24 + raty*(   663/1152/120 + raty*(  29/16/720 + raty*(  -87/24/5040 + raty*( -7/2/40320 +   9/362880*raty))))))))
        asy[2] =  2268/65536 + raty*(  -142884/10321920 + raty*(-204300/645120/2 + raty*(  367740/967680/6 + raty*(  7540/3840/24 + raty*( -4524/1152/120 + raty*(-100/16/720 + raty*(  420/24/5040 + raty*( 20/2/40320 -  36/362880*raty))))))))
        asy[3] = -8820/65536 + raty*(   926100/10321920 + raty*( 745108/645120/2 + raty*(-2235324/967680/6 + raty*(-14748/3840/24 + raty*( 14748/1152/120 + raty*( 156/16/720 + raty*(-1092/24/5040 + raty*(-28/2/40320 +  84/362880*raty))))))))
        asy[4] = 39690/65536 + raty*(-12502350/10321920 + raty*(-574686/645120/2 + raty*( 5172174/967680/6 + raty*(  8614/3840/24 + raty*(-25842/1152/120 + raty*( -82/16/720 + raty*( 1722/24/5040 + raty*( 14/2/40320 - 126/362880*raty))))))))
        asy[5] = 39690/65536 + raty*( 12502350/10321920 + raty*(-574686/645120/2 + raty*(-5172174/967680/6 + raty*(  8614/3840/24 + raty*( 25842/1152/120 + raty*( -82/16/720 + raty*(-1722/24/5040 + raty*( 14/2/40320 + 126/362880*raty))))))))
        asy[6] = -8820/65536 + raty*(  -926100/10321920 + raty*( 745108/645120/2 + raty*( 2235324/967680/6 + raty*(-14748/3840/24 + raty*(-14748/1152/120 + raty*( 156/16/720 + raty*( 1092/24/5040 + raty*(-28/2/40320 -  84/362880*raty))))))))
        asy[7] =  2268/65536 + raty*(   142884/10321920 + raty*(-204300/645120/2 + raty*( -367740/967680/6 + raty*(  7540/3840/24 + raty*(  4524/1152/120 + raty*(-100/16/720 + raty*( -420/24/5040 + raty*( 20/2/40320 +  36/362880*raty))))))))
        asy[8] =  -405/65536 + raty*(   -18225/10321920 + raty*(  37107/645120/2 + raty*(   47709/967680/6 + raty*( -1547/3840/24 + raty*(  -663/1152/120 + raty*(  29/16/720 + raty*(   87/24/5040 + raty*( -7/2/40320 -   9/362880*raty))))))))
        asy[9] =    35/65536 + raty*(     1225/10321920 + raty*(  -3229/645120/2 + raty*(   -3229/967680/6 + raty*(   141/3840/24 + raty*(    47/1152/120 + raty*(  -3/16/720 + raty*(   -7/24/5040 + raty*(  1/2/40320 +   1/362880*raty))))))))
        ix += o[0]-4
        iy += o[1]-4
        fout[mi] = 0.0
        for i in range(10):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(10):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                fout[mi] += f[ixi,iyj]*asx[i]*asy[j]

_s_interp2d_k1 = sjit(_interp2d_k1)
_s_interp2d_k3 = sjit(_interp2d_k3)
_s_interp2d_k5 = sjit(_interp2d_k5)
_s_interp2d_k7 = sjit(_interp2d_k7)
_s_interp2d_k9 = sjit(_interp2d_k9)
_p_interp2d_k1 = pjit(_interp2d_k1)
_p_interp2d_k3 = pjit(_interp2d_k3)
_p_interp2d_k5 = pjit(_interp2d_k5)
_p_interp2d_k7 = pjit(_interp2d_k7)
_p_interp2d_k9 = pjit(_interp2d_k9)

SER_INTERP_2D = [None, _s_interp2d_k1, None, _s_interp2d_k3, None, _s_interp2d_k5, None, _s_interp2d_k7, None, _s_interp2d_k9]
PAR_INTERP_2D = [None, _p_interp2d_k1, None, _p_interp2d_k3, None, _p_interp2d_k5, None, _p_interp2d_k7, None, _p_interp2d_k9]

# extrapolation routines
def _extrapolate2d(f, k, p, c, e):
    padx = (not p[0]) and c[0]
    pady = (not p[1]) and c[1]
    if padx or pady:
        ox = (k//2)+e[0] if padx else 0
        oy = (k//2)+e[1] if pady else 0
        fb = np.zeros([f.shape[0]+2*ox, f.shape[1]+2*oy], dtype=f.dtype)
        _fill2(f, fb, ox, oy)
        if padx:
            _extrapolate1d_x(fb, k, ox)
        if pady:
            _extrapolate1d_y(fb, k, oy)
        return fb, [ox, oy]
    else:
        return f, [0, 0]
    return fb
def _fill2(f, fb, ox, oy):
    nx = f.shape[0]
    ny = f.shape[1]
    if nx*ny < 100000:
        fb[ox:ox+nx, oy:oy+ny] = f
    else:
        __fill2(f, fb, ox, oy)
@numba.njit(parallel=True, cache=True)
def __fill2(f, fb, ox, oy):
    nx = f.shape[0]
    ny = f.shape[1]
    for i in numba.prange(nx):
        for j in range(ny):
            fb[i+ox,j+oy] = f[i,j]
def _compute_bounds(a, b, h, p, c, e, k):
    m = len(a)
    bounds = [_compute_bounds1(a[i], b[i], h[i], p[i], c[i], e[i], k) for i in range(m)]
    return [list(x) for x in zip(*bounds)]

################################################################################
# Three dimensional routines

class interp3d(object):
    def __init__(self, a, b, h, f, k=3, p=[False]*3, c=[True]*3, e=[0]*3):
        """
        See the documentation for interp1d
        this function is the same, except that a, b, h, p, c, and e
        should be lists or tuples of length 3 giving the values for each
        dimension
        the function behaves as in the 1d case, except that of course padding
        is required if padding is requested in any dimension
        """
        if k not in [1, 3, 5, 7, 9]:
            raise Exception('k must be 1, 3, 5, 7, or 9')
        self.a = FloatList(a)
        self.b = FloatList(b)
        self.h = FloatList(h)
        self.f = f
        self.k = k
        self.p = BoolList(p)
        self.c = BoolList(c)
        self.e = IntList(e)
        self.n = IntList(f.shape)
        self.dtype = f.dtype
        self._f, _o = _extrapolate3d(f, k, p, c, e)
        self._o = IntList(_o)
        lb, ub = _compute_bounds(a, b, h, p, c, e, k)
        self.lb = FloatList(lb)
        self.ub = FloatList(ub)
    def __call__(self, xout, yout, zout, fout=None):
        """
        Interpolate to xout
        For 1-D interpolation, xout must be a float
            or a ndarray of floats
        """
        if isinstance(xout, np.ndarray):
            if xout.size > serial_cutoffs[3]:
                func = PAR_INTERP_3D[self.k]
            else:
                func = SER_INTERP_3D[self.k]
            m = int(np.prod(xout.shape))
            copy_made = False
            if fout is None:
                _out = np.empty(m, dtype=self.dtype)
            else:
                _out = fout.ravel()
                if _out.base is None:
                    copy_made = True
            _xout = xout.ravel()
            _yout = yout.ravel()
            _zout = zout.ravel()
            func(self._f, _xout, _yout, _zout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            if copy_made:
                fout[:] = _out
            return _out.reshape(xout.shape)
        else:
            func = SER_INTERP_3D[self.k]
            _xout = np.array([xout],)
            _yout = np.array([yout],)
            _zout = np.array([zout],)
            _out = np.empty(1)
            func(self._f, _xout, _yout, _zout, _out, self.a, self.h, self.n, self.p, self._o, self.lb, self.ub)
            return _out[0]

# interpolation routines
def _interp3d_k1(f, xout, yout, zout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        zr = min(max(zout[mi], lb[2]), ub[2])
        xx = xr - a[0]
        yy = yr - a[1]
        zz = zr - a[2]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        iz = int(zz//h[2])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        ratz = zz/h[2] - (iz+0.5)
        asx = np.empty(2)
        asy = np.empty(2)
        asz = np.empty(2)
        asx[0] = 0.5 - ratx
        asx[1] = 0.5 + ratx
        asy[0] = 0.5 - raty
        asy[1] = 0.5 + raty
        asz[0] = 0.5 - ratz
        asz[1] = 0.5 + ratz
        ix += o[0]
        iy += o[1]
        iz += o[2]
        fout[mi] = 0.0
        for i in range(2):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(2):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                for k in range(2):
                    izk = (iz + k) % n[2] if p[2] else iz + k
                    fout[mi] += f[ixi,iyj,izk]*asx[i]*asy[j]*asz[k]
def _interp3d_k3(f, xout, yout, zout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        zr = min(max(zout[mi], lb[2]), ub[2])
        xx = xr - a[0]
        yy = yr - a[1]
        zz = zr - a[2]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        iz = int(zz//h[2])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        ratz = zz/h[2] - (iz+0.5)
        asx = np.empty(4)
        asy = np.empty(4)
        asz = np.empty(4)
        asx[0] = -1/16 + ratx*( 1/24 + ratx*( 1/4 - ratx/6))
        asx[1] =  9/16 + ratx*( -9/8 + ratx*(-1/4 + ratx/2))
        asx[2] =  9/16 + ratx*(  9/8 + ratx*(-1/4 - ratx/2))
        asx[3] = -1/16 + ratx*(-1/24 + ratx*( 1/4 + ratx/6))
        asy[0] = -1/16 + raty*( 1/24 + raty*( 1/4 - raty/6))
        asy[1] =  9/16 + raty*( -9/8 + raty*(-1/4 + raty/2))
        asy[2] =  9/16 + raty*(  9/8 + raty*(-1/4 - raty/2))
        asy[3] = -1/16 + raty*(-1/24 + raty*( 1/4 + raty/6))
        asz[0] = -1/16 + ratz*( 1/24 + ratz*( 1/4 - ratz/6))
        asz[1] =  9/16 + ratz*( -9/8 + ratz*(-1/4 + ratz/2))
        asz[2] =  9/16 + ratz*(  9/8 + ratz*(-1/4 - ratz/2))
        asz[3] = -1/16 + ratz*(-1/24 + ratz*( 1/4 + ratz/6))
        ix += o[0]-1
        iy += o[1]-1
        iz += o[2]-1
        fout[mi] = 0.0
        for i in range(4):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(4):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                for k in range(4):
                    izk = (iz + k) % n[2] if p[2] else iz + k
                    fout[mi] += f[ixi,iyj,izk]*asx[i]*asy[j]*asz[k]
def _interp3d_k5(f, xout, yout, zout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        zr = min(max(zout[mi], lb[2]), ub[2])
        xx = xr - a[0]
        yy = yr - a[1]
        zz = zr - a[2]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        iz = int(zz//h[2])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        ratz = zz/h[2] - (iz+0.5)
        asx = np.empty(6)
        asy = np.empty(6)
        asz = np.empty(6)
        asx[0] =   3/256 + ratx*(   -9/1920 + ratx*( -5/48/2 + ratx*(  1/8/6 + ratx*( 1/2/24 -  1/8/120*ratx))))
        asx[1] = -25/256 + ratx*(  125/1920 + ratx*( 39/48/2 + ratx*(-13/8/6 + ratx*(-3/2/24 +  5/8/120*ratx))))
        asx[2] = 150/256 + ratx*(-2250/1920 + ratx*(-34/48/2 + ratx*( 34/8/6 + ratx*( 2/2/24 - 10/8/120*ratx))))
        asx[3] = 150/256 + ratx*( 2250/1920 + ratx*(-34/48/2 + ratx*(-34/8/6 + ratx*( 2/2/24 + 10/8/120*ratx))))
        asx[4] = -25/256 + ratx*( -125/1920 + ratx*( 39/48/2 + ratx*( 13/8/6 + ratx*(-3/2/24 -  5/8/120*ratx))))
        asx[5] =   3/256 + ratx*(    9/1920 + ratx*( -5/48/2 + ratx*( -1/8/6 + ratx*( 1/2/24 +  1/8/120*ratx))))
        asy[0] =   3/256 + raty*(   -9/1920 + raty*( -5/48/2 + raty*(  1/8/6 + raty*( 1/2/24 -  1/8/120*raty))))
        asy[1] = -25/256 + raty*(  125/1920 + raty*( 39/48/2 + raty*(-13/8/6 + raty*(-3/2/24 +  5/8/120*raty))))
        asy[2] = 150/256 + raty*(-2250/1920 + raty*(-34/48/2 + raty*( 34/8/6 + raty*( 2/2/24 - 10/8/120*raty))))
        asy[3] = 150/256 + raty*( 2250/1920 + raty*(-34/48/2 + raty*(-34/8/6 + raty*( 2/2/24 + 10/8/120*raty))))
        asy[4] = -25/256 + raty*( -125/1920 + raty*( 39/48/2 + raty*( 13/8/6 + raty*(-3/2/24 -  5/8/120*raty))))
        asy[5] =   3/256 + raty*(    9/1920 + raty*( -5/48/2 + raty*( -1/8/6 + raty*( 1/2/24 +  1/8/120*raty))))
        asz[0] =   3/256 + ratz*(   -9/1920 + ratz*( -5/48/2 + ratz*(  1/8/6 + ratz*( 1/2/24 -  1/8/120*ratz))))
        asz[1] = -25/256 + ratz*(  125/1920 + ratz*( 39/48/2 + ratz*(-13/8/6 + ratz*(-3/2/24 +  5/8/120*ratz))))
        asz[2] = 150/256 + ratz*(-2250/1920 + ratz*(-34/48/2 + ratz*( 34/8/6 + ratz*( 2/2/24 - 10/8/120*ratz))))
        asz[3] = 150/256 + ratz*( 2250/1920 + ratz*(-34/48/2 + ratz*(-34/8/6 + ratz*( 2/2/24 + 10/8/120*ratz))))
        asz[4] = -25/256 + ratz*( -125/1920 + ratz*( 39/48/2 + ratz*( 13/8/6 + ratz*(-3/2/24 -  5/8/120*ratz))))
        asz[5] =   3/256 + ratz*(    9/1920 + ratz*( -5/48/2 + ratz*( -1/8/6 + ratz*( 1/2/24 +  1/8/120*ratz))))
        ix += o[0]-2
        iy += o[1]-2
        iz += o[2]-2
        fout[mi] = 0.0
        for i in range(6):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(6):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                for k in range(6):
                    izk = (iz + k) % n[2] if p[2] else iz + k
                    fout[mi] += f[ixi,iyj,izk]*asx[i]*asy[j]*asz[k]
def _interp3d_k7(f, xout, yout, zout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        zr = min(max(zout[mi], lb[2]), ub[2])
        xx = xr - a[0]
        yy = yr - a[1]
        zz = zr - a[2]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        iz = int(zz//h[2])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        ratz = zz/h[2] - (iz+0.5)
        asx = np.empty(8)
        asy = np.empty(8)
        asz = np.empty(8)
        asx[0] =   -5/2048 + ratx*(     75/107520 + ratx*(  259/11520/2 + ratx*(  -37/1920/6 + ratx*(  -7/48/24 + ratx*(   5/24/120 + ratx*( 1/2/720 -  1/5040*ratx))))))
        asx[1] =   49/2048 + ratx*(  -1029/107520 + ratx*(-2495/11520/2 + ratx*(  499/1920/6 + ratx*(  59/48/24 + ratx*( -59/24/120 + ratx*(-5/2/720 +  7/5040*ratx))))))
        asx[2] = -245/2048 + ratx*(   8575/107520 + ratx*(11691/11520/2 + ratx*(-3897/1920/6 + ratx*(-135/48/24 + ratx*( 225/24/120 + ratx*( 9/2/720 - 21/5040*ratx))))))
        asx[3] = 1225/2048 + ratx*(-128625/107520 + ratx*(-9455/11520/2 + ratx*( 9455/1920/6 + ratx*(  83/48/24 + ratx*(-415/24/120 + ratx*(-5/2/720 + 35/5040*ratx))))))
        asx[4] = 1225/2048 + ratx*( 128625/107520 + ratx*(-9455/11520/2 + ratx*(-9455/1920/6 + ratx*(  83/48/24 + ratx*( 415/24/120 + ratx*(-5/2/720 - 35/5040*ratx))))))
        asx[5] = -245/2048 + ratx*(  -8575/107520 + ratx*(11691/11520/2 + ratx*( 3897/1920/6 + ratx*(-135/48/24 + ratx*(-225/24/120 + ratx*( 9/2/720 + 21/5040*ratx))))))
        asx[6] =   49/2048 + ratx*(   1029/107520 + ratx*(-2495/11520/2 + ratx*( -499/1920/6 + ratx*(  59/48/24 + ratx*(  59/24/120 + ratx*(-5/2/720 -  7/5040*ratx))))))
        asx[7] =   -5/2048 + ratx*(    -75/107520 + ratx*(  259/11520/2 + ratx*(   37/1920/6 + ratx*(  -7/48/24 + ratx*(  -5/24/120 + ratx*( 1/2/720 +  1/5040*ratx))))))
        asy[0] =   -5/2048 + raty*(     75/107520 + raty*(  259/11520/2 + raty*(  -37/1920/6 + raty*(  -7/48/24 + raty*(   5/24/120 + raty*( 1/2/720 -  1/5040*raty))))))
        asy[1] =   49/2048 + raty*(  -1029/107520 + raty*(-2495/11520/2 + raty*(  499/1920/6 + raty*(  59/48/24 + raty*( -59/24/120 + raty*(-5/2/720 +  7/5040*raty))))))
        asy[2] = -245/2048 + raty*(   8575/107520 + raty*(11691/11520/2 + raty*(-3897/1920/6 + raty*(-135/48/24 + raty*( 225/24/120 + raty*( 9/2/720 - 21/5040*raty))))))
        asy[3] = 1225/2048 + raty*(-128625/107520 + raty*(-9455/11520/2 + raty*( 9455/1920/6 + raty*(  83/48/24 + raty*(-415/24/120 + raty*(-5/2/720 + 35/5040*raty))))))
        asy[4] = 1225/2048 + raty*( 128625/107520 + raty*(-9455/11520/2 + raty*(-9455/1920/6 + raty*(  83/48/24 + raty*( 415/24/120 + raty*(-5/2/720 - 35/5040*raty))))))
        asy[5] = -245/2048 + raty*(  -8575/107520 + raty*(11691/11520/2 + raty*( 3897/1920/6 + raty*(-135/48/24 + raty*(-225/24/120 + raty*( 9/2/720 + 21/5040*raty))))))
        asy[6] =   49/2048 + raty*(   1029/107520 + raty*(-2495/11520/2 + raty*( -499/1920/6 + raty*(  59/48/24 + raty*(  59/24/120 + raty*(-5/2/720 -  7/5040*raty))))))
        asy[7] =   -5/2048 + raty*(    -75/107520 + raty*(  259/11520/2 + raty*(   37/1920/6 + raty*(  -7/48/24 + raty*(  -5/24/120 + raty*( 1/2/720 +  1/5040*raty))))))
        asz[0] =   -5/2048 + ratz*(     75/107520 + ratz*(  259/11520/2 + ratz*(  -37/1920/6 + ratz*(  -7/48/24 + ratz*(   5/24/120 + ratz*( 1/2/720 -  1/5040*ratz))))))
        asz[1] =   49/2048 + ratz*(  -1029/107520 + ratz*(-2495/11520/2 + ratz*(  499/1920/6 + ratz*(  59/48/24 + ratz*( -59/24/120 + ratz*(-5/2/720 +  7/5040*ratz))))))
        asz[2] = -245/2048 + ratz*(   8575/107520 + ratz*(11691/11520/2 + ratz*(-3897/1920/6 + ratz*(-135/48/24 + ratz*( 225/24/120 + ratz*( 9/2/720 - 21/5040*ratz))))))
        asz[3] = 1225/2048 + ratz*(-128625/107520 + ratz*(-9455/11520/2 + ratz*( 9455/1920/6 + ratz*(  83/48/24 + ratz*(-415/24/120 + ratz*(-5/2/720 + 35/5040*ratz))))))
        asz[4] = 1225/2048 + ratz*( 128625/107520 + ratz*(-9455/11520/2 + ratz*(-9455/1920/6 + ratz*(  83/48/24 + ratz*( 415/24/120 + ratz*(-5/2/720 - 35/5040*ratz))))))
        asz[5] = -245/2048 + ratz*(  -8575/107520 + ratz*(11691/11520/2 + ratz*( 3897/1920/6 + ratz*(-135/48/24 + ratz*(-225/24/120 + ratz*( 9/2/720 + 21/5040*ratz))))))
        asz[6] =   49/2048 + ratz*(   1029/107520 + ratz*(-2495/11520/2 + ratz*( -499/1920/6 + ratz*(  59/48/24 + ratz*(  59/24/120 + ratz*(-5/2/720 -  7/5040*ratz))))))
        asz[7] =   -5/2048 + ratz*(    -75/107520 + ratz*(  259/11520/2 + ratz*(   37/1920/6 + ratz*(  -7/48/24 + ratz*(  -5/24/120 + ratz*( 1/2/720 +  1/5040*ratz))))))
        ix += o[0]-3
        iy += o[1]-3
        iz += o[2]-3
        fout[mi] = 0.0
        for i in range(8):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(8):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                for k in range(8):
                    izk = (iz + k) % n[2] if p[2] else iz + k
                    fout[mi] += f[ixi,iyj,izk]*asx[i]*asy[j]*asz[k]
def _interp3d_k9(f, xout, yout, zout, fout, a, h, n, p, o, lb, ub):
    m = fout.shape[0]
    for mi in numba.prange(m):
        xr = min(max(xout[mi], lb[0]), ub[0])
        yr = min(max(yout[mi], lb[1]), ub[1])
        zr = min(max(zout[mi], lb[2]), ub[2])
        xx = xr - a[0]
        yy = yr - a[1]
        zz = zr - a[2]
        ix = int(xx//h[0])
        iy = int(yy//h[1])
        iz = int(zz//h[2])
        ratx = xx/h[0] - (ix+0.5)
        raty = yy/h[1] - (iy+0.5)
        ratz = zz/h[2] - (iz+0.5)
        asx = np.empty(10)
        asy = np.empty(10)
        asz = np.empty(10)
        asx[0] =    35/65536 + ratx*(    -1225/10321920 + ratx*(  -3229/645120/2 + ratx*(    3229/967680/6 + ratx*(   141/3840/24 + ratx*(   -47/1152/120 + ratx*(  -3/16/720 + ratx*(    7/24/5040 + ratx*(  1/2/40320 -   1/362880*ratx))))))))
        asx[1] =  -405/65536 + ratx*(    18225/10321920 + ratx*(  37107/645120/2 + ratx*(  -47709/967680/6 + ratx*( -1547/3840/24 + ratx*(   663/1152/120 + ratx*(  29/16/720 + ratx*(  -87/24/5040 + ratx*( -7/2/40320 +   9/362880*ratx))))))))
        asx[2] =  2268/65536 + ratx*(  -142884/10321920 + ratx*(-204300/645120/2 + ratx*(  367740/967680/6 + ratx*(  7540/3840/24 + ratx*( -4524/1152/120 + ratx*(-100/16/720 + ratx*(  420/24/5040 + ratx*( 20/2/40320 -  36/362880*ratx))))))))
        asx[3] = -8820/65536 + ratx*(   926100/10321920 + ratx*( 745108/645120/2 + ratx*(-2235324/967680/6 + ratx*(-14748/3840/24 + ratx*( 14748/1152/120 + ratx*( 156/16/720 + ratx*(-1092/24/5040 + ratx*(-28/2/40320 +  84/362880*ratx))))))))
        asx[4] = 39690/65536 + ratx*(-12502350/10321920 + ratx*(-574686/645120/2 + ratx*( 5172174/967680/6 + ratx*(  8614/3840/24 + ratx*(-25842/1152/120 + ratx*( -82/16/720 + ratx*( 1722/24/5040 + ratx*( 14/2/40320 - 126/362880*ratx))))))))
        asx[5] = 39690/65536 + ratx*( 12502350/10321920 + ratx*(-574686/645120/2 + ratx*(-5172174/967680/6 + ratx*(  8614/3840/24 + ratx*( 25842/1152/120 + ratx*( -82/16/720 + ratx*(-1722/24/5040 + ratx*( 14/2/40320 + 126/362880*ratx))))))))
        asx[6] = -8820/65536 + ratx*(  -926100/10321920 + ratx*( 745108/645120/2 + ratx*( 2235324/967680/6 + ratx*(-14748/3840/24 + ratx*(-14748/1152/120 + ratx*( 156/16/720 + ratx*( 1092/24/5040 + ratx*(-28/2/40320 -  84/362880*ratx))))))))
        asx[7] =  2268/65536 + ratx*(   142884/10321920 + ratx*(-204300/645120/2 + ratx*( -367740/967680/6 + ratx*(  7540/3840/24 + ratx*(  4524/1152/120 + ratx*(-100/16/720 + ratx*( -420/24/5040 + ratx*( 20/2/40320 +  36/362880*ratx))))))))
        asx[8] =  -405/65536 + ratx*(   -18225/10321920 + ratx*(  37107/645120/2 + ratx*(   47709/967680/6 + ratx*( -1547/3840/24 + ratx*(  -663/1152/120 + ratx*(  29/16/720 + ratx*(   87/24/5040 + ratx*( -7/2/40320 -   9/362880*ratx))))))))
        asx[9] =    35/65536 + ratx*(     1225/10321920 + ratx*(  -3229/645120/2 + ratx*(   -3229/967680/6 + ratx*(   141/3840/24 + ratx*(    47/1152/120 + ratx*(  -3/16/720 + ratx*(   -7/24/5040 + ratx*(  1/2/40320 +   1/362880*ratx))))))))
        asy[0] =    35/65536 + raty*(    -1225/10321920 + raty*(  -3229/645120/2 + raty*(    3229/967680/6 + raty*(   141/3840/24 + raty*(   -47/1152/120 + raty*(  -3/16/720 + raty*(    7/24/5040 + raty*(  1/2/40320 -   1/362880*raty))))))))
        asy[1] =  -405/65536 + raty*(    18225/10321920 + raty*(  37107/645120/2 + raty*(  -47709/967680/6 + raty*( -1547/3840/24 + raty*(   663/1152/120 + raty*(  29/16/720 + raty*(  -87/24/5040 + raty*( -7/2/40320 +   9/362880*raty))))))))
        asy[2] =  2268/65536 + raty*(  -142884/10321920 + raty*(-204300/645120/2 + raty*(  367740/967680/6 + raty*(  7540/3840/24 + raty*( -4524/1152/120 + raty*(-100/16/720 + raty*(  420/24/5040 + raty*( 20/2/40320 -  36/362880*raty))))))))
        asy[3] = -8820/65536 + raty*(   926100/10321920 + raty*( 745108/645120/2 + raty*(-2235324/967680/6 + raty*(-14748/3840/24 + raty*( 14748/1152/120 + raty*( 156/16/720 + raty*(-1092/24/5040 + raty*(-28/2/40320 +  84/362880*raty))))))))
        asy[4] = 39690/65536 + raty*(-12502350/10321920 + raty*(-574686/645120/2 + raty*( 5172174/967680/6 + raty*(  8614/3840/24 + raty*(-25842/1152/120 + raty*( -82/16/720 + raty*( 1722/24/5040 + raty*( 14/2/40320 - 126/362880*raty))))))))
        asy[5] = 39690/65536 + raty*( 12502350/10321920 + raty*(-574686/645120/2 + raty*(-5172174/967680/6 + raty*(  8614/3840/24 + raty*( 25842/1152/120 + raty*( -82/16/720 + raty*(-1722/24/5040 + raty*( 14/2/40320 + 126/362880*raty))))))))
        asy[6] = -8820/65536 + raty*(  -926100/10321920 + raty*( 745108/645120/2 + raty*( 2235324/967680/6 + raty*(-14748/3840/24 + raty*(-14748/1152/120 + raty*( 156/16/720 + raty*( 1092/24/5040 + raty*(-28/2/40320 -  84/362880*raty))))))))
        asy[7] =  2268/65536 + raty*(   142884/10321920 + raty*(-204300/645120/2 + raty*( -367740/967680/6 + raty*(  7540/3840/24 + raty*(  4524/1152/120 + raty*(-100/16/720 + raty*( -420/24/5040 + raty*( 20/2/40320 +  36/362880*raty))))))))
        asy[8] =  -405/65536 + raty*(   -18225/10321920 + raty*(  37107/645120/2 + raty*(   47709/967680/6 + raty*( -1547/3840/24 + raty*(  -663/1152/120 + raty*(  29/16/720 + raty*(   87/24/5040 + raty*( -7/2/40320 -   9/362880*raty))))))))
        asy[9] =    35/65536 + raty*(     1225/10321920 + raty*(  -3229/645120/2 + raty*(   -3229/967680/6 + raty*(   141/3840/24 + raty*(    47/1152/120 + raty*(  -3/16/720 + raty*(   -7/24/5040 + raty*(  1/2/40320 +   1/362880*raty))))))))
        asz[0] =    35/65536 + ratz*(    -1225/10321920 + ratz*(  -3229/645120/2 + ratz*(    3229/967680/6 + ratz*(   141/3840/24 + ratz*(   -47/1152/120 + ratz*(  -3/16/720 + ratz*(    7/24/5040 + ratz*(  1/2/40320 -   1/362880*ratz))))))))
        asz[1] =  -405/65536 + ratz*(    18225/10321920 + ratz*(  37107/645120/2 + ratz*(  -47709/967680/6 + ratz*( -1547/3840/24 + ratz*(   663/1152/120 + ratz*(  29/16/720 + ratz*(  -87/24/5040 + ratz*( -7/2/40320 +   9/362880*ratz))))))))
        asz[2] =  2268/65536 + ratz*(  -142884/10321920 + ratz*(-204300/645120/2 + ratz*(  367740/967680/6 + ratz*(  7540/3840/24 + ratz*( -4524/1152/120 + ratz*(-100/16/720 + ratz*(  420/24/5040 + ratz*( 20/2/40320 -  36/362880*ratz))))))))
        asz[3] = -8820/65536 + ratz*(   926100/10321920 + ratz*( 745108/645120/2 + ratz*(-2235324/967680/6 + ratz*(-14748/3840/24 + ratz*( 14748/1152/120 + ratz*( 156/16/720 + ratz*(-1092/24/5040 + ratz*(-28/2/40320 +  84/362880*ratz))))))))
        asz[4] = 39690/65536 + ratz*(-12502350/10321920 + ratz*(-574686/645120/2 + ratz*( 5172174/967680/6 + ratz*(  8614/3840/24 + ratz*(-25842/1152/120 + ratz*( -82/16/720 + ratz*( 1722/24/5040 + ratz*( 14/2/40320 - 126/362880*ratz))))))))
        asz[5] = 39690/65536 + ratz*( 12502350/10321920 + ratz*(-574686/645120/2 + ratz*(-5172174/967680/6 + ratz*(  8614/3840/24 + ratz*( 25842/1152/120 + ratz*( -82/16/720 + ratz*(-1722/24/5040 + ratz*( 14/2/40320 + 126/362880*ratz))))))))
        asz[6] = -8820/65536 + ratz*(  -926100/10321920 + ratz*( 745108/645120/2 + ratz*( 2235324/967680/6 + ratz*(-14748/3840/24 + ratz*(-14748/1152/120 + ratz*( 156/16/720 + ratz*( 1092/24/5040 + ratz*(-28/2/40320 -  84/362880*ratz))))))))
        asz[7] =  2268/65536 + ratz*(   142884/10321920 + ratz*(-204300/645120/2 + ratz*( -367740/967680/6 + ratz*(  7540/3840/24 + ratz*(  4524/1152/120 + ratz*(-100/16/720 + ratz*( -420/24/5040 + ratz*( 20/2/40320 +  36/362880*ratz))))))))
        asz[8] =  -405/65536 + ratz*(   -18225/10321920 + ratz*(  37107/645120/2 + ratz*(   47709/967680/6 + ratz*( -1547/3840/24 + ratz*(  -663/1152/120 + ratz*(  29/16/720 + ratz*(   87/24/5040 + ratz*( -7/2/40320 -   9/362880*ratz))))))))
        asz[9] =    35/65536 + ratz*(     1225/10321920 + ratz*(  -3229/645120/2 + ratz*(   -3229/967680/6 + ratz*(   141/3840/24 + ratz*(    47/1152/120 + ratz*(  -3/16/720 + ratz*(   -7/24/5040 + ratz*(  1/2/40320 +   1/362880*ratz))))))))
        ix += o[0]-4
        iy += o[1]-4
        iz += o[2]-4
        fout[mi] = 0.0
        for i in range(10):
            ixi = (ix + i) % n[0] if p[0] else ix + i
            for j in range(10):
                iyj = (iy + j) % n[1] if p[1] else iy + j
                for k in range(10):
                    izk = (iz + k) % n[2] if p[2] else iz + k
                    fout[mi] += f[ixi,iyj,izk]*asx[i]*asy[j]*asz[k]

_s_interp3d_k1 = sjit(_interp3d_k1)
_s_interp3d_k3 = sjit(_interp3d_k3)
_s_interp3d_k5 = sjit(_interp3d_k5)
_s_interp3d_k7 = sjit(_interp3d_k7)
_s_interp3d_k9 = sjit(_interp3d_k9)
_p_interp3d_k1 = pjit(_interp3d_k1)
_p_interp3d_k3 = pjit(_interp3d_k3)
_p_interp3d_k5 = pjit(_interp3d_k5)
_p_interp3d_k7 = pjit(_interp3d_k7)
_p_interp3d_k9 = pjit(_interp3d_k9)

SER_INTERP_3D = [None, _s_interp3d_k1, None, _s_interp3d_k3, None, _s_interp3d_k5, None, _s_interp3d_k7, None, _s_interp3d_k9]
PAR_INTERP_3D = [None, _p_interp3d_k1, None, _p_interp3d_k3, None, _p_interp3d_k5, None, _p_interp3d_k7, None, _p_interp3d_k9]

# extrapolation routines
def _extrapolate3d(f, k, p, c, e):
    padx = (not p[0]) and c[0]
    pady = (not p[1]) and c[1]
    padz = (not p[2]) and c[2]
    if padx or pady or padz:
        ox = (k//2)+e[0] if padx else 0
        oy = (k//2)+e[1] if pady else 0
        oz = (k//2)+e[2] if padz else 0
        fb = np.zeros([f.shape[0]+2*ox, f.shape[1]+2*oy, f.shape[2]+2*oz], dtype=f.dtype)
        _fill3(f, fb, ox, oy, oz)
        if padx:
            _extrapolate1d_x(fb, k, ox)
        if pady:
            _extrapolate1d_y(fb, k, oy)
        if padz:
            _extrapolate1d_z(fb, k, oz)
        return fb, [ox, oy, oz]
    else:
        return f, [0, 0, 0]
    return fb
def _fill3(f, fb, ox, oy, oz):
    nx = f.shape[0]
    ny = f.shape[1]
    nz = f.shape[2]
    if nx*ny*nz < 100000:
        fb[ox:ox+nx, oy:oy+ny, oz:oz+nz] = f
    else:
        __fill3(f, fb, ox, oy, oz)
@numba.njit(parallel=True, cache=True)
def __fill3(f, fb, ox, oy, oz):
    nx = f.shape[0]
    ny = f.shape[1]
    nz = f.shape[2]
    for i in numba.prange(nx):
        for j in range(ny):
            for k in range(nz):
                fb[i+ox,j+oy,k+oz] = f[i,j,k]
