import matplotlib.pyplot as plt
from agx_emulsion.profiles.factory import create_profile, plot_profile, remove_density_min
from agx_emulsion.profiles.io import load_profile

p = create_profile('kodak_portra_400')
p = remove_density_min(p)
plot_profile(p)
plt.show()


p = load_profile('kodak_portra_400')
plot_profile(p)
p = load_profile('kodak_portra_400_v2')
plot_profile(p)
plt.show()