import numpy as np
from agx_emulsion.utils.fast_interp_lut import apply_lut_cubic_3d, apply_lut_cubic_2d

def _create_lut_3d(function, xmin=0, xmax=1, steps=32):
    x = np.linspace(xmin, xmax, steps, endpoint=True)
    X = np.meshgrid(x,x,x, indexing='ij')
    X = np.stack(X, axis=3)
    X = np.reshape(X, (steps**2, steps, 3)) # shape as an image to be compatible with image processing
    lut = np.reshape(function(X), (steps, steps, steps, 3))
    return lut

# def _create_lut_2d(function, xmin=0, xmax=1, steps=128):
#     x = np.linspace(xmin, xmax, steps, endpoint=True)
#     X = np.meshgrid(x,x, indexing='ij')
#     X = np.stack(X, axis=3)
#     X = np.reshape(X, (steps, steps, 3)) # shape as an image to be compatible with image processing
#     lut = np.reshape(function(X), (steps, steps, 3))
#     return lut

def compute_with_lut(data, function, xmin=0, xmax=1, steps=32):
    lut = _create_lut_3d(function, xmin, xmax, steps)
    return apply_lut_cubic_3d(lut, data), lut

def warmup_luts():
    """
    Performs a warmup for both 3D and 2D LUT JIT functions.
    This ensures that the Numba JIT compilation overhead is incurred only once.
    """
    L = 32
    grid = np.linspace(0, 1, L, dtype=np.float64)
    
    # --- Warmup 3D LUT ---
    R, G, B = np.meshgrid(grid, grid, grid, indexing='ij')
    lut_3d = np.stack((R**2, G**2, B**2), axis=-1)  # 3D LUT: shape (L,L,L,3)
    height, width = 128, 128
    x = np.linspace(0, 1, width, dtype=np.float64)
    y = np.linspace(0, 1, height, dtype=np.float64)
    X, Y = np.meshgrid(x, y)
    image_3d = np.stack((X, Y, 0.5 * np.ones_like(X)), axis=-1)
    _ = apply_lut_cubic_3d(lut_3d, image_3d)
    
    # --- Warmup 2D LUT ---
    # Define a 2D LUT mapping (x,y) chromaticities to RGB.
    L = 128
    grid = np.linspace(0, 1, L, dtype=np.float64)
    lut_2d = np.empty((L, L, 3), dtype=np.float64)
    X2, Y2 = np.meshgrid(grid, grid, indexing='ij')
    lut_2d[..., 0] = X2**2         # R = x^2
    lut_2d[..., 1] = Y2**2         # G = y^2
    lut_2d[..., 2] = (X2 + Y2) / 2.0  # B = (x+y)/2
    # Create a synthetic image of chromaticities (2 channels).
    image_2d = np.stack((X, Y), axis=-1)
    _ = apply_lut_cubic_2d(lut_2d, image_2d)

if __name__=='__main__':
    import matplotlib.pyplot as plt
        
    def mycalculation(x):
        y = np.zeros_like(x)
        y[:,:,0] = 3*x[:,:,1] + x[:,:,0]
        y[:,:,1] = 3*x[:,:,2] + x[:,:,1]
        y[:,:,2] = 3*x[:,:,0] + x[:,:,2]
        return y

    warmup_luts()
    np.random.seed(0)
    data = np.random.uniform(0,1,size=(300,200,3))
    lut3d = _create_lut_3d(mycalculation)
    data_finterp = apply_lut_cubic_3d(lut3d, data)
    error = mycalculation(data)-data_finterp
    print('Max interpolation error:',np.max(error))
    print('Mean interpolation error:',np.mean(np.abs(error)))
    plt.show()