import numpy as np
from agx_emulsion.utils.fast_interp import interp3d

def _create_lut3d(function, xmin=0, xmax=1, steps=32):
    x = np.linspace(xmin, xmax, steps, endpoint=True)
    X = np.meshgrid(x,x,x)
    X = np.stack(X, axis=3)
    X = np.reshape(X, (steps**3, 1, 3)) # shape as an image to be compatible with normal processing
    return x, function(X)
  
def _fast_interpolate_lut3d(data, lut, x, method='cubic'):
    steps = np.size(x) 
    xmin = np.min(x)
    xmax = np.max(x)
    h = (xmax - xmin)/(steps-1) # regular grid step
    lut3d = np.reshape(lut, (steps, steps, steps , 3))
    data_out = np.zeros_like(data)
    if method=='linear': k=1
    if method=='cubic': k=3
    for i in np.arange(3):        
        interpolator = interp3d([xmin]*3, [xmax]*3, [h]*3, lut3d[:,:,:,i], k=k)
        data_out[:,:,i] = interpolator(data[:,:,0], data[:,:,1], data[:,:,2])
    data_out = data_out[:,:,(1,0,2)] # reorder xy with ij indexing
    return data_out

def compute_with_lut(data, function, method='cubic', xmin=0, xmax=1, steps=32):
    x, lut = _create_lut3d(function, xmin, xmax, steps)
    return _fast_interpolate_lut3d(data, lut, x, method)

if __name__=='__main__':
    import matplotlib.pyplot as plt
    def imshow_lut(lut):
        steps = np.int32(np.size(lut, 0)**(1/3)+1)
        lut_image = np.reshape(lut, (steps*4, np.int32(steps**2/4), 3))
        plt.imshow(lut_image)
        plt.axis('off')

    def mycalculation(x):
        return x
    
    x, lut = _create_lut3d(mycalculation)
    np.random.seed(0)
    data = np.random.uniform(0,1,size=(3000,2000,3))
    data_finterp = _fast_interpolate_lut3d(data, lut, x)
    error = mycalculation(data)-data_finterp
    print('Max interpolation error:',np.max(error))
    
    imshow_lut(lut)
    plt.show()