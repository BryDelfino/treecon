import 'package:flutter/material.dart';

class SignInPage extends StatefulWidget {
    const SignInPage({super.key});

    @override
    State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {

    @override 
    Widget build(BuildContext context) {
        return Scaffold(
            body: Center (
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                        const Text.rich(
                            TextSpan(
                                text: 'TREECON ',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 48,
                                    color: Colors.green,
                                ),
                                children: [
                                    TextSpan(
                                        text: 'COMMANDER',
                                        style: TextStyle(
                                            fontStyle: FontStyle.italic,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black,
                                        ),
                                    ),
                                ],
                            ),
                        ),
                        const Text(
                            'Sign In',
                            style: TextStyle(
                                fontSize: 32,
                            ),
                        ),
                        
                        const SizedBox(height: 10.0),

                        SizedBox(
                            width: 500,
                            child: TextFormField(
                                decoration: const InputDecoration(
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(10.0)),
                                    ),
                                    labelText: 'Email Address',
                                    prefixIcon: Icon(Icons.email),
                                ),
                            ),
                        ),

                        const SizedBox(height: 10.0),

                        SizedBox(
                            width: 500,
                            child: TextFormField(
                                decoration: const InputDecoration(
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.all(Radius.circular(10.0)),
                                    ),
                                    labelText: 'Password',
                                    prefixIcon: Icon(Icons.lock),
                                ),
                            ),
                        ), 

                        const SizedBox(height: 25.0), 

                        TextButton(
                            style: TextButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.all(Radius.circular(10.0)),
                                ),
                                foregroundColor: Colors.green,
                                fixedSize: Size(100,60),
                            ),
                            onPressed: () {},
                            child: const Text('Sign In'),
                        ),

                        const SizedBox(height: 25.0), 
                        
                    ],
                ),  
            ),
        );
    }







}