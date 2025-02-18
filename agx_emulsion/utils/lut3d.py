import numpy as np
import scipy.interpolate
from agx_emulsion.utils.fast_interp import interp3d

def _create_lut3d(function, xmin=0, xmax=1, steps=32):
    x = np.linspace(xmin, xmax, steps, endpoint=True)
    X = np.meshgrid(x,x,x)
    X = np.stack(X, axis=3)
    X = np.reshape(X, (steps**3, 1, 3)) # shape as an image to be compatible with normal processing
    return x, function(X)

def _interpolate_lut3d(data, lut, x, method='cubic'):
    steps = np.int32(np.size(lut, 0)**(1/3)+1)
    lut3d = np.reshape(lut, (steps, steps, steps, 3))
    interpolator = scipy.interpolate.RegularGridInterpolator((x,x,x), lut3d, method=method) # this is too slow to be usable
    data_out = interpolator(data[:,:,(1,0,2)])
    return data_out

def _fast_interpolate_lut3d(data, lut, x, method='cubic'):
    steps = np.size(x)
    xmin = np.min(x)
    xmax = np.max(x)
    h = (xmax - xmin)/(steps-1) # regular grid step
    lut3d = np.reshape(lut, (steps, steps, steps , 3))
    data_out = np.zeros_like(data)
    if method=='linear': k=1
    if method=='cubic':  k=3
    for i in np.arange(3):        
        interpolator = interp3d([xmin]*3, [xmax]*3, [h]*3, lut3d[:,:,:,i], k=k)
        data_out[:,:,i] = interpolator(data[:,:,1], data[:,:,0], data[:,:,2]) # note the flip of xy for ij-ordering
    return data_out

def compute_with_lut(data, function, method='cubic', xmin=0, xmax=1, steps=32, fast_interp=True):
    x, lut = _create_lut3d(function, xmin, xmax, steps)
    if fast_interp:
        data_out = _fast_interpolate_lut3d(data, lut, x, method)
    else:
        data_out = _interpolate_lut3d(data, lut, x, method)
    return data_out

if __name__=='__main__':
    import matplotlib.pyplot as plt
    def imshow_lut(lut):
        steps = np.int32(np.size(lut, 0)**(1/3)+1)
        lut_image = np.reshape(lut, (steps*4, np.int32(steps**2/4), 3))
        plt.imshow(lut_image)
        plt.axis('off')
        
    def mycalculation(x):
        y = np.zeros_like(x)
        y[:,:,0] = 3*x[:,:,1] + x[:,:,0]
        y[:,:,1] = 3*x[:,:,2] + x[:,:,1]
        y[:,:,2] = 3*x[:,:,0] + x[:,:,2]
        return y

    np.random.seed(0)
    data = np.random.uniform(0,1,size=(300,200,3))
    x, lut = _create_lut3d(mycalculation, steps=32)
    data_finterp = _fast_interpolate_lut3d(data, lut, x)
    data_scipy_interp = _interpolate_lut3d(data, lut, x)
    error = mycalculation(data)-data_finterp
    error_scipy = mycalculation(data)-data_scipy_interp
    print('Max interpolation error fast_interp:',np.max(error))
    print('Max interpolation error scipy:',np.max(error_scipy))
    print('Mean interpolation error fast_interp:',np.mean(np.abs(error)))
    print('Mean interpolation error scipy:',np.mean(np.abs(error_scipy)))
    
    imshow_lut(lut/np.max(lut))
    plt.show()