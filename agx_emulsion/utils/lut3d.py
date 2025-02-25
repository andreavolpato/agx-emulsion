import numpy as np
from agx_emulsion.utils.fast_interp_lut3d import apply_lut_cubic

def _create_lut3d(function, xmin=0, xmax=1, steps=32):
    x = np.linspace(xmin, xmax, steps, endpoint=True)
    X = np.meshgrid(x,x,x, indexing='ij')
    X = np.stack(X, axis=3)
    X = np.reshape(X, (steps**2, steps, 3)) # shape as an image to be compatible with image processing
    lut = np.reshape(function(X), (steps, steps, steps, 3))
    return lut

def compute_with_lut(data, function, xmin=0, xmax=1, steps=32):
    lut = _create_lut3d(function, xmin, xmax, steps)
    # lut = np.ascontiguousarray(lut)
    return apply_lut_cubic(lut, data)

def warmup_lut3d():
    L = 32
    grid = np.linspace(0, 1, L, dtype=np.float64)
    R, G, B = np.meshgrid(grid, grid, grid, indexing='ij')
    lut = np.stack((R**2, G**2, B**2), axis=-1)  # double precision; unbounded output
    
    # --- Create a Synthetic Test Image ---
    # Generate a clear gradient image:
    # - Red channel varies horizontally,
    # - Green channel varies vertically,
    # - Blue channel is fixed at 0.5.
    height, width = 128, 128
    x = np.linspace(0, 1, width, dtype=np.float64)
    y = np.linspace(0, 1, height, dtype=np.float64)
    X, Y = np.meshgrid(x, y)
    image = np.stack((X, Y, 0.5 * np.ones_like(X)), axis=-1)  # double precision
    
    # --- Warm Up the JIT Compiler ---
    _ = apply_lut_cubic(lut, image)

if __name__=='__main__':
    import matplotlib.pyplot as plt
        
    def mycalculation(x):
        y = np.zeros_like(x)
        y[:,:,0] = 3*x[:,:,1] + x[:,:,0]
        y[:,:,1] = 3*x[:,:,2] + x[:,:,1]
        y[:,:,2] = 3*x[:,:,0] + x[:,:,2]
        return y

    warmup_lut3d()
    np.random.seed(0)
    data = np.random.uniform(0,1,size=(300,200,3))
    lut = _create_lut3d(mycalculation)
    data_finterp = apply_lut_cubic(lut, data)
    error = mycalculation(data)-data_finterp
    print('Max interpolation error:',np.max(error))
    print('Mean interpolation error:',np.mean(np.abs(error)))
    plt.show()