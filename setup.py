from setuptools import find_packages, setup

setup(name='agx-emulsion',
      version='0.1.0',
      description='Simulation of analog film photography',
      author='Andrea Volpato',
      author_email='volpedellenevi@gmail.com',
      license='GPLv3',
      packages=find_packages(),
      package_data={'agx_emulsion': ['data/**/*']},
      zip_safe=False,
      entry_points={
          'console_scripts': [
              'agx-emulsion = agx_emulsion.gui.main:main',
          ]
      },
      )
