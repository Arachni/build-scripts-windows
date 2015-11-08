# Arachni build-scripts for MS Windows

This repository holds scripts which are used to build self-contained packages for Arachni.

The scripts pull-in the WebUI repository which in turn pulls in the Framework as a dependency.

## Options

* `branch` --  [WebUI](https://github.com/Arachni/arachni-ui-web/) branch to pull.
    * Default: `experimental`
* `build_dir` -- Directory for the built packages.
    * Default: `./arachni`
    * The path used during the build process should not contain spaces.
* `package` -- Create self-extracting archive?
    * Default: `$false`

## Dependencies

* [7zip](http://www.7-zip.org/)
