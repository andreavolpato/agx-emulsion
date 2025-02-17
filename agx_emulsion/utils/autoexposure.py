import numpy as np
import colour

def measure_autoexposure_ev(image, color_space='sRGB', apply_cctf_decoding=True, method='center_weighted'):
    # approximation of luminance L = 0.2126 * R + 0.7152 * G + 0.0722 * B
    image_XYZ = colour.RGB_to_XYZ(image, color_space, apply_cctf_decoding=apply_cctf_decoding)
    image_Y = image_XYZ[:,:,1]
    if method == 'median':
        Y_exposure = np.median(image_Y)
    if method == 'center_weighted':
        norm_shape = image.shape[0:2]/np.max(image.shape[0:2])
        x = np.arange(image.shape[1]) / image.shape[1]
        y = np.arange(image.shape[0]) / image.shape[0]
        x -= 0.5
        y -= 0.5
        x *= norm_shape[1]
        y *= norm_shape[0]
        sigma = 0.2 # should be 0.2 to 0.3
        mask = np.exp(-(x**2 + y[:,None]**2)/(2*sigma**2))
        mask /= np.sum(mask)
        Y_exposure = np.sum(image_Y*mask)

    exposure = Y_exposure / 0.184
    exposure_compensation_ev = - np.log2(exposure)
    if np.isinf(exposure_compensation_ev):
        exposure_compensation_ev = 0.0
        print('Warning: Autoexposure is Inf. Setting autoexposure compensation to 0 EV.')
    return exposure_compensation_ev


if __name__=='__main__':
    import matplotlib.pyplot as plt
    image = np.random.uniform(0, 1, (3000,2000, 3))
    exposure_ev = measure_autoexposure_ev(image)
    print(exposure_ev)
    plt.imshow(image)
    plt.show()