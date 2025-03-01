import numpy as np
import numba
import time

@numba.njit(parallel=True, fastmath=True, cache=True)
def fast_interp(image, x_axis, y_vals):
    """
    Perform 1-D linear interpolation on an N-dimensional array where the
    last dimension is 3. The x_axis can be:
      - a 1D array of length K (common for all channels), or
      - a 2D array of shape (K,3) (each column for a channel).
    
    For values outside the x range, the first (if too small) or last (if too large)
    value from the y_vals (which is Kx3) is returned.
    
    Uses precomputed reciprocal differences from the monotonic x_axis for efficiency.
    
    Parameters:
      image: an array of shape (..., 3) containing new x values.
      x_axis: sorted x axis, either a 1D array (shape (K,)) or 2D array (shape (K,3)).
      y_vals: a Kx3 array of reference y values for each channel.
      
    Returns:
      result: an array of the same shape as image with interpolated values.
    """
    # Compute total number of "pixels" (all dims except the last).
    shape = image.shape
    n = 1
    for i in range(len(shape) - 1):
        n *= shape[i]
    flat_image = image.reshape(n, 3)
    flat_result = np.empty_like(flat_image)
    
    K = x_axis.shape[0]
    common_axis = (x_axis.ndim == 1)
    
    # Precompute reciprocal differences (for monotonic x_axis).
    if common_axis:
        inv_dx_common = np.empty(K - 1, dtype=x_axis.dtype)
        for i in range(K - 1):
            inv_dx_common[i] = 1.0 / (x_axis[i+1] - x_axis[i])
    else:
        inv_dx = np.empty((K - 1, 3), dtype=x_axis.dtype)
        for c in range(3):
            for i in range(K - 1):
                inv_dx[i, c] = 1.0 / (x_axis[i+1, c] - x_axis[i, c])
    
    # Process each "pixel" (each row of length 3).
    for i in numba.prange(n):
        for c in range(3):
            x = flat_image[i, c]
            # Choose proper x_axis and inv_dx for this channel.
            if common_axis:
                xa = x_axis
                inv_dx_val = inv_dx_common  # array of length K-1
            else:
                # For channel-specific, use the corresponding column.
                xa = x_axis[:, c]
                inv_dx_val = inv_dx[:, c]
            # Extrapolation: if x is outside, return the endpoint y.
            if x <= xa[0]:
                flat_result[i, c] = y_vals[0, c]
            elif x >= xa[K - 1]:
                flat_result[i, c] = y_vals[K - 1, c]
            else:
                idx = np.searchsorted(xa, x)
                low = idx - 1
                x0 = xa[low]
                # Use precomputed reciprocal to avoid division in inner loop.
                t = (x - x0) * inv_dx_val[low]
                flat_result[i, c] = y_vals[low, c] + t * (y_vals[low + 1, c] - y_vals[low, c])
                
    return flat_result.reshape(shape)

def np_interp_for_image(image, x_axis, y_vals):
    """
    Uses np.interp to perform interpolation on an N-dimensional array where the
    last dimension is 3. Handles both common (1D) and channel-specific (2D)
    x_axis.
    """
    shape = image.shape
    flat_image = image.reshape(-1, 3)
    flat_result = np.empty_like(flat_image)
    if x_axis.ndim == 1:
        for c in range(3):
            flat_result[:, c] = np.interp(flat_image[:, c], x_axis, y_vals[:, c])
    else:
        for c in range(3):
            flat_result[:, c] = np.interp(flat_image[:, c], x_axis[:, c], y_vals[:, c])
    return flat_result.reshape(shape)

def warmup_fast_interp():
    """
    Perform a dummy interpolation to precompile fast_interp for both common (1D)
    and channel-specific (2D) x_axis cases.
    """
    shape = (10, 10, 3)
    K = 5
    # Warmup with common x_axis.
    dummy_x_axis = np.linspace(0, 1, K)
    dummy_y_vals = np.zeros((K, 3), dtype=np.float64)
    dummy_image = np.random.rand(*shape).astype(np.float64)
    _ = fast_interp(dummy_image, dummy_x_axis, dummy_y_vals)
    
    # Warmup with channel-specific x_axis.
    dummy_x_axis2 = np.linspace(0, 1, K).reshape(K, 1)
    dummy_x_axis2 = np.repeat(dummy_x_axis2, 3, axis=1)
    _ = fast_interp(dummy_image, dummy_x_axis2, dummy_y_vals)

if __name__ == '__main__':
    # Precompile the fast_interp function.
    warmup_fast_interp()
    
    # Configuration for testing.
    shape = (6000, 4000, 3)  # Example: a high-resolution image.
    K = 1024                # Number of interpolation reference points.
    
    # Create a common x_axis (1D).
    x_axis_common = np.linspace(0, 1, K)
    
    # Create a channel-specific x_axis (2D, shape: (K,3)).
    x_axis_2d = np.linspace(0, 1, K).reshape(K, 1)
    x_axis_2d = np.repeat(x_axis_2d, 3, axis=1)
    
    # Create a Kx3 array for y values.
    # For example, Channel 0: quadratic, Channel 1: square root, Channel 2: sine.
    y_vals = np.empty((K, 3), dtype=np.float64)
    y_vals[:, 0] = x_axis_common**2
    y_vals[:, 1] = np.sqrt(x_axis_common)
    y_vals[:, 2] = np.sin(x_axis_common * np.pi)
    
    # Create a random N-dimensional array (values in [0, 1]) of the given shape.
    image = np.random.rand(*shape).astype(np.float64)
    
    # Test with common x_axis (1D)
    res_fast_common = fast_interp(image, x_axis_common, y_vals)
    res_np_common = np_interp_for_image(image, x_axis_common, y_vals)
    error_common = np.abs(res_np_common - res_fast_common).max()
    print("Maximum error (common x_axis):", error_common)
    
    # Test with channel-specific x_axis (2D)
    res_fast_2d = fast_interp(image, x_axis_2d, y_vals)
    res_np_2d = np_interp_for_image(image, x_axis_2d, y_vals)
    error_2d = np.abs(res_np_2d - res_fast_2d).max()
    print("Maximum error (2D x_axis):", error_2d)
    
    iterations = 10
    
    # Timing for common x_axis.
    start = time.perf_counter()
    for _ in range(iterations):
        _ = fast_interp(image, x_axis_common, y_vals)
    fast_time_common = (time.perf_counter() - start) / iterations
    start = time.perf_counter()
    for _ in range(iterations):
        _ = np_interp_for_image(image, x_axis_common, y_vals)
    np_time_common = (time.perf_counter() - start) / iterations
    print("Common x_axis - Average time per iteration (fast_interp): {:.6f} sec".format(fast_time_common))
    print("Common x_axis - Average time per iteration (np.interp): {:.6f} sec".format(np_time_common))
    
    # Timing for channel-specific x_axis.
    start = time.perf_counter()
    for _ in range(iterations):
        _ = fast_interp(image, x_axis_2d, y_vals)
    fast_time_2d = (time.perf_counter() - start) / iterations
    start = time.perf_counter()
    for _ in range(iterations):
        _ = np_interp_for_image(image, x_axis_2d, y_vals)
    np_time_2d = (time.perf_counter() - start) / iterations
    print("2D x_axis - Average time per iteration (fast_interp): {:.6f} sec".format(fast_time_2d))
    print("2D x_axis - Average time per iteration (np.interp): {:.6f} sec".format(np_time_2d))
