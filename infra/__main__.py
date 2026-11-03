import pulumi


env = pulumi.get_stack()
pulumi.export("env", env)
